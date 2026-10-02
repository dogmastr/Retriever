--!strict
--[[
	Turns a stored `d` into data the running code can use: defaults for new profiles, versioned migrations, template/schema
	fill and validation. Also the pure dry run used by tools (`Retriever.dryRun`).

	Runs outside any DataStore callback (after the session lock is held), so migrations may be slow, may allocate freely and
	cannot be replayed by the engine. A failure never touches the stored record: the loader releases the lock and reports
	`MigrationFailed` or `InvalidData`.

	Versions (mixed-version safety rules):
	* `sv` is the schema version of the stored `d`; `mr` the minimum schema version a server must run to load it.
	* A migration is "breaking" (default) or "forward". Data in the shape of version N needs a reader that understands the
	  highest breaking version <= N, so after preparing data at this server's version the session's minimum reader is
	  `config.minReader` (the highest breaking version of the store), whether the steps ran now or earlier, and also for a
	  brand-new profile created in the current shape.
	* `Record.acquire` refuses a record whose `mr` is above the server's version (`SchemaTooNew`) atomically with the lock, and
	  `Record.write` refuses to write over one, so an older server can neither load nor overwrite data a newer schema produced.
	* A record whose `sv` is newer than this server but whose `mr` allows it (only forward steps since) is loaded as is: no
	  step runs, unknown fields are preserved, and `sv`/`mr` never move backwards on save.
	* If schema validation fails right after migrating, the error is `MigrationFailed` (the steps produced invalid data) with
	  `step` = the last version applied; without migrations it is `InvalidData`. Both carry the path of the problem.
]]

local Codec = require(script.Parent.Codec)
local Internal = require(script.Parent.Internal)
local Schema = require(script.Parent.Schema)
local Types = require(script.Parent.Types)
local Util = require(script.Parent.Util)

type StoreConfigN = Internal.StoreConfigN

export type Prepared = {
	ok: true,
	data: any,
	--- True when the in-memory data differs from what is stored (new, migrated or filled): it must be saved.
	changed: boolean,
	created: boolean,
	--- Minimum reader the data requires once it is written; nil leaves the record's `mr` as it is.
	minReader: number?,
}

export type Failed = {
	ok: false,
	kind: Types.ErrorKind,
	cause: string,
	step: number?,
	--- Path of the invalid value (`data.items[3]`) when validation failed.
	path: string?,
}

export type StepReport = {
	version: number,
	name: string?,
	compat: "breaking" | "forward",
}

export type DryRunOptions = {
	--- Schema version of `value` when it is plain data (not a record). Default 1.
	version: number?,
	--- Minimum reader of `value` when it is plain data. Default nil.
	minReader: number?,
	--- Whether `value` is a stored record (`{ v, r, e, sv, mr, d, ... }`) or plain data. Default: detected from the shape
	--- (numeric `v`, `r` and `e`), so pass `false` for plain data that happens to have such fields.
	record: boolean?,
	--- Stop after this version (step-by-step testing). Default: the store's schema version. Validation against the schema
	--- runs only when the target is the store's version (the schema describes that shape).
	to: number?,
}

export type DryRunReport = {
	ok: boolean,
	--- Why the load would fail: SchemaTooNew | Corrupt | MigrationFailed | InvalidData | InvalidArgument.
	kind: Types.ErrorKind?,
	cause: string?,
	step: number?,
	path: string?,
	--- Version of the input data and of the result (`sv` after a save).
	from: number,
	to: number,
	--- `mr` the record would have after the next save.
	minReader: number?,
	--- Steps that ran, in order (up to and including the failing one).
	applied: { StepReport },
	created: boolean,
	--- True when a load would have to save (new, migrated or filled).
	changed: boolean,
	--- The migrated copy; the input is never modified. Nil when a step failed before producing data.
	data: any,
}

local Migrate = {}

--- Highest breaking migration version <= `version`, or nil when every step up to it is forward-compatible.
function Migrate.minReaderFor(config: StoreConfigN, version: number): number?
	local result: number? = nil
	for _, migration in config.migrations do
		if migration.version > version then
			break
		end
		if migration.compat ~= "forward" then
			result = migration.version
		end
	end
	return result
end

--- Fresh default data for a new profile.
function Migrate.defaults(config: StoreConfigN): any
	local schema = config.schema
	if schema ~= nil then
		return schema:defaults()
	end
	local template = config.template
	if template ~= nil then
		return Util.deepCopy(template)
	end
	return {}
end

--- Runs the steps in (from, to]. Returns the data, the last version applied and a failure, if any. `trace` collects reports.
local function runSteps(
	config: StoreConfigN,
	data: any,
	from: number,
	to: number,
	trace: { StepReport }?
): (any, number?, Failed?)
	local last: number? = nil
	for _, migration in config.migrations do
		local version = migration.version
		if version > from and version <= to then
			if trace ~= nil then
				local step: StepReport = {
					version = version,
					name = migration.name,
					compat = if migration.compat == "forward" then "forward" else "breaking",
				}
				table.insert(trace, step)
			end
			local label = if migration.name ~= nil then `migration to version {version} ("{migration.name}")` else `migration to version {version}`
			local ok, result = pcall(migration.up, data)
			if not ok then
				return data, version, { ok = false, kind = "MigrationFailed", cause = `{label} raised: {tostring(result)}`, step = version }
			end
			if type(result) ~= "table" then
				return data,
					version,
					{
						ok = false,
						kind = "MigrationFailed",
						cause = `{label} must return the migrated table, got {typeof(result)}`,
						step = version,
					}
			end
			data = result
			last = version
		end
	end
	return data, last, nil
end

--- Fill from the schema (or template), then validate against the schema. `migratedTo` is the last step applied, if any.
local function reconcile(config: StoreConfigN, data: any, migratedTo: number?): (boolean, Failed?)
	local schema = config.schema
	if schema == nil then
		local template = config.template
		return template ~= nil and Util.fill(data, template), nil
	end
	-- pcall: a custom (non-DSL) schema that raises must fail this load cleanly (the loader then releases the lock), not
	-- unwind through the load pipeline with the lock still held.
	local filled, ok, message = false, false, nil :: string?
	local called, raised = pcall(function()
		filled = schema:fill(data)
		ok, message = schema:check(data)
	end)
	if not called then
		ok, message = false, `the schema raised an error: {tostring(raised)}`
	end
	if ok then
		return filled, nil
	end
	local text = message or "does not match the schema"
	if migratedTo ~= nil then
		return filled,
			{
				ok = false,
				kind = "MigrationFailed",
				cause = `the data produced by the migrations does not match the schema: {text}`,
				step = migratedTo,
				path = Schema.pathOf(text),
			}
	end
	return filled, { ok = false, kind = "InvalidData", cause = text, path = Schema.pathOf(text) }
end

--- `stored` is the record's `d` (nil for a new profile); `storedVersion` its `sv` (nil = 1). Migrates `stored` in place
--- (the loader never writes it back on failure).
function Migrate.prepare(config: StoreConfigN, stored: any, storedVersion: number?): Prepared | Failed
	if stored == nil then
		local data = Migrate.defaults(config)
		return { ok = true, data = data, changed = true, created = true, minReader = config.minReader }
	end
	if type(stored) ~= "table" then
		return { ok = false, kind = "Corrupt", cause = `stored data is a {typeof(stored)}, expected a table` }
	end

	local from = storedVersion or 1
	local target = config.schemaVersion
	local data: any = stored
	local changed = false
	local last: number? = nil
	if from < target then
		local failure
		data, last, failure = runSteps(config, data, from, target, nil)
		if failure ~= nil then
			return failure
		end
		changed = true
	end

	local filled, failure = reconcile(config, data, last)
	if failure ~= nil then
		return failure
	end
	-- Data at (or migrated to) this server's version needs this version's minimum reader; data from a newer, compatible
	-- server keeps the record's own `mr` (nil here; the loader merges `rec.mr`).
	local minReader = if from <= target then config.minReader else nil
	return { ok = true, data = data, changed = changed or filled, created = false, minReader = minReader }
end

--- Simulates loading `value` on a server running `config` without touching anything: the acquire-time version check,
--- the migrations (on a deep copy), fill and validation. `value` is a Retriever record (as stored) or plain data.
function Migrate.dryRun(config: StoreConfigN, value: any, options: DryRunOptions?): DryRunReport
	local opts: DryRunOptions = options or {}
	local target = config.schemaVersion
	local stored: any = value
	local from = opts.version or 1
	local recordMinReader = opts.minReader
	local isRecord = opts.record
	if isRecord == nil then
		isRecord = type(value) == "table" and type(value.v) == "number" and type(value.r) == "number" and type(value.e) == "number"
	elseif isRecord and type(value) ~= "table" then
		return {
			ok = false,
			kind = "InvalidArgument",
			cause = `options.record is true but the value is a {typeof(value)}, not a record table`,
			step = nil,
			path = nil,
			from = from,
			to = from,
			minReader = recordMinReader,
			applied = {},
			created = false,
			changed = false,
			data = nil,
		}
	end
	if isRecord then
		stored = value.d
		if value.cd ~= nil then
			-- encoded record (Retriever.codec): migrate the decoded data
			local decodedOk, decoded = Codec.decode(value.cd, value.cv, stored, nil)
			if not decodedOk then
				return {
					ok = false,
					kind = "Corrupt",
					cause = decoded,
					step = nil,
					path = nil,
					from = if type(value.sv) == "number" then value.sv else 1,
					to = if type(value.sv) == "number" then value.sv else 1,
					minReader = if type(value.mr) == "number" then value.mr else nil,
					applied = {},
					created = false,
					changed = false,
					data = nil,
				}
			end
			stored = decoded
		end
		from = if type(value.sv) == "number" then value.sv else 1
		recordMinReader = if type(value.mr) == "number" then value.mr else nil
	end
	local to = opts.to or target

	local report: DryRunReport = {
		ok = false,
		kind = nil,
		cause = nil,
		step = nil,
		path = nil,
		from = from,
		to = from,
		minReader = recordMinReader,
		applied = {},
		created = stored == nil,
		changed = false,
		data = nil,
	}
	local function refuse(kind: Types.ErrorKind, cause: string, failure: Failed?): DryRunReport
		report.kind = kind
		report.cause = cause
		if failure ~= nil then
			report.step = failure.step
			report.path = failure.path
		end
		return report
	end

	if to > target or to < 1 or math.floor(to) ~= to then
		return refuse("InvalidArgument", `options.to must be a version between 1 and {target}, got {to}`)
	end
	if opts.to ~= nil and to < from and from <= target then
		return refuse("InvalidArgument", `options.to ({to}) is below the version of the data ({from}); migrations only run upwards`)
	end
	if recordMinReader ~= nil and recordMinReader > target then
		return refuse(
			"SchemaTooNew",
			`record schema version {from}, minimum reader {recordMinReader}, this server runs {target}: it would refuse to load it`
		)
	end
	if stored == nil then
		local data = Migrate.defaults(config)
		report.ok = true
		report.data = data
		report.to = target
		report.changed = true
		report.minReader = config.minReader
		return report
	end
	if type(stored) ~= "table" then
		return refuse("Corrupt", `stored data is a {typeof(stored)}, expected a table`)
	end

	local data: any = Util.deepCopy(stored)
	local last: number? = nil
	local changed = false
	if from < to then
		local failure
		data, last, failure = runSteps(config, data, from, to, report.applied)
		if failure ~= nil then
			report.data = nil
			return refuse(failure.kind, failure.cause, failure)
		end
		changed = true
		report.to = to
	end
	if to == target then
		local filled, failure = reconcile(config, data, last)
		if failure ~= nil then
			report.data = data
			return refuse(failure.kind, failure.cause, failure)
		end
		changed = changed or filled
	end

	local minReader = recordMinReader
	if from <= to then
		local needed = Migrate.minReaderFor(config, to)
		if needed ~= nil and (minReader == nil or needed > minReader) then
			minReader = needed
		end
	end
	report.ok = true
	report.data = data
	report.changed = changed
	report.minReader = minReader
	return report
end

return Migrate
