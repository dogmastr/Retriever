# Retriever

Retriever saves and loads player data in Roblox games. You describe what a new player's data looks like, then read and
change it like a normal Luau table. Retriever loads the data when a player joins, saves it while they play, and saves it
again when they leave or the server shuts down.

Its main goal is that a player's data is **never lost and never duplicated**, even when servers crash, Roblox's
DataStores fail, or players hop between servers. It's an alternative to libraries like ProfileStore.

## Contents

- [Why Retriever?](#why-retriever)
- [Words used in this guide](#words-used-in-this-guide)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Reading and changing data](#reading-and-changing-data)
- [Using the data from other scripts](#using-the-data-from-other-scripts)
- [Saving right now](#saving-right-now)
- [Doing something only once](#doing-something-only-once)
- [Selling Developer Products](#selling-developer-products)
- [When loading fails](#when-loading-fails)
- [Changing your data over time](#changing-your-data-over-time)
- [Schemas](#schemas)
- [Testing in Studio](#testing-in-studio)
- [Settings](#settings)
- [Errors](#errors)
- [More features](#more-features): commands, admin tools, monitoring, shared data, trades, compression
- [API reference](#api-reference)
- [Troubleshooting](#troubleshooting)
- [Tips](#tips)

---

## Why Retriever?

Saving with `DataStoreService` directly looks easy, but a few common situations lose or duplicate data:

- A player leaves one server and joins another before the first server finished saving, so the new server loads **old
  data**.
- Two servers save the same player at the same time, and one **overwrites** the other.
- A load fails, the game gives the player fresh default data, and that **blank data gets saved** over their real
  progress.
- A Robux purchase is granted, the server crashes before saving, and the player **paid for nothing**, or the purchase is
  granted **twice**.

Retriever handles all of these for you:

- **Session locking.** Only one server at a time can change a player's data. When a player joins a new server, it asks
  the old server to save and hand the data over.
- **Automatic saving.** Data is loaded when a player joins, saved in the background while they play, and saved and
  released when they leave or the server shuts down.
- **No blank-data overwrites.** If loading fails, the player is asked to rejoin instead of getting default data.
- **Confirmed saves** when you need them, plus actions and Robux purchases that happen **exactly once**.
- **Safe updates.** New fields are filled in automatically, migrations update old data, and servers still running an
  older version of your game can't overwrite data that newer servers already updated.
- **Optional extras**: schemas, gifts to offline players, admin tools, shared data like guilds, safe trades,
  compression, and monitoring.

---

## Words used in this guide

| Word | Meaning |
| --- | --- |
| **DataStore** | Roblox's built-in database for keeping data between play sessions. Retriever uses it for you. |
| **Store** | One named DataStore plus its settings, made with `Retriever.store("PlayerData", { ... })`. |
| **Key** | The name one piece of data is saved under. For players it's their user id as text, like `"123456"`. |
| **Template** | What a brand-new player's data looks like. |
| **Profile** | The loaded data for one key. `profile.data` is the table you read and change. |
| **Session** | The time a profile is loaded on a server. During a session the server holds a **lock**, so no other server can change that data. |

---

## Installation

### 1. Download

On this repository's GitHub page, click the green **Code** button, choose **Download ZIP**, and unzip it. The library is
the `src/Retriever` folder: `init.luau` plus 34 other `.luau` files.

### 2. Add it to your game

**Option A: copy the files by hand (no extra tools)**

1. In Roblox Studio, add a **ModuleScript** to **ServerScriptService** and rename it to `Retriever`.
2. Open `src/Retriever/init.luau` in any text editor, copy all of it, and paste it into the `Retriever` ModuleScript,
   replacing the code that's already there.
3. For each of the other 34 files, add a ModuleScript **inside** `Retriever` (in the Explorer, hover over `Retriever`,
   click **+** and pick **ModuleScript**), give it the file's name without `.luau` (`Store.luau` becomes `Store`), and
   paste the file's contents into it.

The result should look like this. Names are case-sensitive, because the modules find each other by name.

```text
ServerScriptService
└── Retriever        ← ModuleScript with the code from init.luau
    ├── Admin        ← ModuleScript with the code from Admin.luau
    ├── Classify
    ├── Codec
    └── ...          ← 34 child ModuleScripts in total
```

The 34 children are: Admin, Classify, Codec, Commands, Compress, Diff, Dispatcher, Documents, Errors, Escrow, Events,
Handoff, Heap, Histogram, Internal, Lane, MemoryBackend, Metrics, Migrate, Patch, Players, Profile, Receipts, Record,
Ring, RobloxEnv, Runtime, Scheduler, Schema, Store, Types, UserKey, Util and Validate.

**Option B: sync with Rojo or Argon**

If you sync your project from files with [Rojo](https://rojo.space) or Argon, copy the `src/Retriever` folder into your
project and map it in your project file. For example, if you copied it to `lib/Retriever`:

```json
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": {
      "$className": "ServerScriptService",
      "Retriever": { "$path": "lib/Retriever" }
    }
  }
}
```

The folder becomes a `Retriever` ModuleScript with all 34 children.

### 3. Let Studio save (recommended)

To test real saving in Studio, publish your place, then open **Game Settings → Security** and turn on **Enable Studio
Access to API Services**. Without it, Retriever still runs in Studio, but it keeps data in memory only and prints a
warning that nothing will be saved. See [Testing in Studio](#testing-in-studio).

> Retriever runs **only on the server**. Use it from a `Script` in ServerScriptService (or from a ModuleScript that such
> a Script requires), never from a LocalScript.

---

## Quick start

This is a complete, working example. Put it in a **Script** in ServerScriptService:

```lua
local ServerScriptService = game:GetService("ServerScriptService")
local Retriever = require(ServerScriptService.Retriever)

-- 1. Describe what a brand-new player's data looks like.
local template = {
	coins = 0,
	level = 1,
	inventory = {}, -- items the player owns, like { Sword = true }
}

-- 2. Create a store. "PlayerData" is the DataStore's name.
local store = Retriever.store("PlayerData", {
	template = template,
	studio = "prefix", -- in Studio, use separate test data (see "Testing in Studio")
})

-- 3. Load every player automatically.
local players = Retriever.players(store, {
	onLoaded = function(player, profile)
		print(player.Name, "has", profile.data.coins, "coins")

		-- Give a welcome bonus.
		profile:edit(function(data)
			data.coins += 10
		end)
	end,
})
```

Press **Play**. The output shows your coins, and (with Studio API access on) the number goes up by 10 every time you
play.

That's all the setup you need. Retriever now:

- loads each player's data when they join (including players who were already in the server),
- saves changes automatically in the background (within 60 seconds of a change, by default),
- saves and releases a player's data when they leave,
- saves everyone's data when the server shuts down, and early when Roblox announces a server restart.

The `players` value returned by `Retriever.players` is how the rest of your code finds a player's profile. See
[Using the data from other scripts](#using-the-data-from-other-scripts).

---

## Reading and changing data

`profile.data` is a normal Luau table. **Read** it whenever you like:

```lua
print(profile.data.coins)

if profile.data.inventory.Sword then
	print("This player owns a sword")
end
```

**Change** it inside `profile:edit`, which tells Retriever there is something new to save:

```lua
profile:edit(function(data)
	data.coins += 50
	data.inventory.Sword = true
end)
```

Changes show up immediately and are saved automatically. You never need to call a save function yourself.

Two rules for `edit`:

- **Don't yield inside it.** No `task.wait`, DataStore or HTTP calls: just change the data and return.
- **Don't edit after the player left.** When a player leaves, their profile closes, and editing a closed profile raises
  an error (the change could never be saved). In code that might run late, for example after a `task.wait`, check
  `profile:isActive()` first.

### Changing data directly

In code that runs very often, you can skip the function and change `profile.data` directly. Then call
`profile:touch()`, which marks the profile as changed:

```lua
profile.data.coins += 1
profile:touch()
```

Without `touch`, the change stays in memory but isn't saved until something else causes a save, such as another edit or
the player leaving.

---

## Using the data from other scripts

Most games use player data in many scripts: shops, quests, leaderboards. Put the setup in one **ModuleScript** and
require it everywhere, so every script shares the same store. Here is a complete module that also shows each player's
coins in the player list:

```lua
-- A ModuleScript named "PlayerData" in ServerScriptService
local ServerScriptService = game:GetService("ServerScriptService")
local Retriever = require(ServerScriptService.Retriever)

local store = Retriever.store("PlayerData", {
	template = {
		coins = 0,
		level = 1,
		inventory = {},
	},
	studio = "prefix",
})

local players = Retriever.players(store, {
	onLoaded = function(player, profile)
		-- Show the coins in the player list.
		local leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		local coins = Instance.new("IntValue")
		coins.Name = "Coins"
		coins.Value = profile.data.coins
		coins.Parent = leaderstats
		leaderstats.Parent = player
	end,
})

local PlayerData = {
	store = store,
	players = players,
}

-- Adds coins to a player. Returns false if their data isn't loaded.
function PlayerData.addCoins(player, amount)
	local profile = players:get(player)
	if not profile then
		return false
	end
	profile:edit(function(data)
		data.coins += amount
	end)
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		leaderstats.Coins.Value = profile.data.coins
	end
	return true
end

return PlayerData
```

Then, in any server script:

```lua
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerData = require(ServerScriptService.PlayerData)

PlayerData.addCoins(player, 25)

-- Get a profile right now (nil while it's still loading):
local profile = PlayerData.players:get(player)

-- Or wait until it has loaded (nil if loading failed or the player left):
local profile = PlayerData.players:wait(player)
```

> Require your data module **at the top** of each script, before you connect your own `Players.PlayerAdded` handlers.
> `players:wait(player)` returns `nil` right away for a player that Retriever hasn't started loading yet.

---

## Saving right now

Automatic saving is enough most of the time. For important moments, like after a trade or a big purchase, you can wait
until the data is **confirmed saved**:

```lua
profile:edit(function(data)
	data.coins -= 1000
	data.inventory.Dragon = true
end)

local result = profile:commit()
if result.ok then
	print("Saved for sure!")
else
	warn("Not confirmed:", result.error.message)
end
```

`commit` waits (yields) until everything you changed before calling it is saved, for up to 30 seconds
(`profile:commit({ timeout = 60 })` changes that). If Retriever can't tell whether a save went through, for example
because Roblox's reply got lost, it returns an error with `kind = "Unknown"` instead of pretending it worked. Retriever
keeps saving in the background, and calling `commit` again settles it.

You don't need `commit` in normal play. Use it when something outside the data depends on the save, such as telling
the player "Trade complete!".

---

## Doing something only once

Some actions can arrive twice: a reward that's retried after an error, or a request handled by two servers. Give each
action a **unique id** and use `profile:apply`. Retriever makes sure it happens only **once** for that profile, even
across servers, crashes and rejoins:

```lua
local today = os.date("!%Y-%m-%d") -- today's date in UTC, like "2026-10-02"

local result = profile:apply("daily-reward-" .. today, function(data)
	data.coins += 100
end)

if result == "duplicate" then
	print("Already claimed today")
end
```

`apply` returns `"applied"` the first time and `"duplicate"` every time after that. The id is saved together with the
change, so the two are always saved, or lost, together.

Good to know:

- Each profile remembers its last **200** ids for **30 days** (the `ledger` [setting](#settings)). Older ids are
  forgotten, so `apply` is for recent events. For "has this player *ever* done X", keep a field in the data.
- **Check first, then change.** If your function errors halfway, the id isn't recorded, but whatever it changed before
  the error stays changed.
- Like `edit`, don't yield inside it. Calling it on a profile that isn't active raises an error.

---

## Selling Developer Products

Developer Products are things players can buy with Robux again and again, like coins or boosts. Roblox sends each
purchase to your game, and your game must answer whether it granted the purchase. Mistakes here lose purchases or grant
them twice.

Retriever can handle purchases for you: each one is granted **exactly once**, and Roblox is told "granted" only after
the save is confirmed. Add this to your data module, right after `Retriever.players(...)`:

```lua
Retriever.receipts(players, {
	[123456789] = function(player, profile, receipt) -- your Developer Product id
		profile.data.coins += 1000
	end,
	[987654321] = function(player, profile, receipt)
		profile.data.inventory.SpeedBoost = true
	end,
})
```

- Call `Retriever.receipts` **once, when the server starts**, before anything that yields (`task.wait`,
  `WaitForChild`, ...), so it's ready before the first purchase arrives.
- Inside a handler, change `profile.data` directly. Handlers already run inside `apply` (with the purchase id as the
  id), so you don't need `edit`. Don't yield inside them.
- If anything goes wrong (the player left, their data isn't loaded, the handler errored, the save failed or took too
  long), Retriever tells Roblox the purchase is **not processed yet**. Roblox keeps the purchase and sends it again
  later, for example when the player rejoins. A purchase that's sent again is never granted twice.
- Each purchase is decided within 8 seconds, because Roblox resends unanswered purchases about every 10 seconds.

Optional settings go in a third argument:

```lua
local receipts = Retriever.receipts(players, handlers, {
	onGranted = function(player, receipt)
		print(player.Name, "bought product", receipt.ProductId)
	end,
})
```

| Option | Default | What it does |
| --- | --- | --- |
| `timeout` | `8` | Seconds one purchase may take: waiting for the data to load plus the confirmed save. |
| `onGranted` | none | `function(player, receipt)`, called after a purchase was granted and saved. |
| `otherwise` | none | `function(receipt)` for products without a handler. Return `"granted"` or `"notProcessedYet"`. Without it, those purchases stay unprocessed and a warning is printed. |
| `useProcessReceipt` | `false` | Use the classic `MarketplaceService.ProcessReceipt` callback even when the newer `BindReceiptHandler` is available. |
| `install` | `true` | `false` installs nothing. Your own `ProcessReceipt` then calls `receipts:process(receiptInfo)`, which returns `"granted"` or `"notProcessedYet"`. |

`receipts:stats()` counts `granted`, `duplicates`, `deferred` and `failed` purchases, and `receipts:disconnect()` stops
granting.

> Game Passes are different: they're bought once and checked with `MarketplaceService:UserOwnsGamePassAsync`. They
> don't go through `Retriever.receipts`.

---

## When loading fails

If a player's data can't be loaded, for example because Roblox's DataStores are down or another server won't let go of
the data, Retriever **will not** give them blank default data, because that blank data could be saved over their real
data. By default it kicks the player with a message asking them to rejoin.

A session can also **end while the player is still in the server**, usually because another server took the data over
(see [When another server doesn't let go](#when-another-server-doesnt-let-go)). This server can no longer save their
progress, so by default the player is kicked as well.

You can handle both yourself:

```lua
Retriever.players(store, {
	onLoaded = function(player, profile)
		-- ...
	end,
	onFailed = function(player, err)
		warn("Could not load", player.Name, err.kind, err.message)
		player:Kick("We couldn't load your data. Please rejoin in a minute.")
	end,
	onEnded = function(player, reason, err)
		player:Kick("Your data is being used by another server. Please rejoin.")
	end,
})
```

If you replace these, don't let the player keep playing as if nothing happened: anything they earn can't be saved.

---

## Changing your data over time

### Adding fields

When you add a field to your template, existing players get it automatically the next time they join:

```lua
local template = {
	coins = 0,
	level = 1,
	inventory = {},
	pets = {}, -- new! existing players get an empty table on their next join
}
```

Retriever only fills in **missing** fields. It never changes a value a player already has.

> **Keep collections of owned things empty in the template.** Missing fields are filled in inside nested tables too, so
> with `inventory = { Sword = true }` in the template, every player without a sword (say, one who sold it) would get it
> back on every join. Give starting items in code instead:

```lua
-- template: { coins = 0, inventory = {}, starterItemsGiven = false }
if not profile.data.starterItemsGiven then
	profile:edit(function(data)
		data.inventory.Sword = true
		data.starterItemsGiven = true
	end)
end
```

### Migrations

You need a **migration** when you change data that players already have: renaming a field, splitting one into two, or
changing how something is stored. A migration is a function that turns the old shape into the new one:

```lua
local store = Retriever.store("PlayerData", {
	template = template,
	studio = "prefix",
	migrations = {
		{
			version = 2,
			name = "rename gold to coins",
			up = function(data)
				data.coins = data.gold or 0
				data.gold = nil
				return data
			end,
		},
	},
})
```

How it works:

- Data that never had a migration is **version 1**. Your first migration is `version = 2`, the next one `version = 3`,
  and so on, with no gaps.
- When a player's data loads, each migration it hasn't had yet runs once, in order. Then missing template fields are
  filled in.
- `up` receives the data and must **return** it (the same table, or a new one).
- New players start from the template, so keep the template in the **newest** shape.
- Never change or remove a migration after you published it. Add a new one instead.
- If a migration errors, nothing is saved: the player's data stays as it was, and the player gets the "could not load"
  kick. Fix the migration and publish again.

**During game updates**, Roblox doesn't restart all servers at once, so old and new servers run side by side for a
while. Once a new server migrates a player's data to version 2, an old server (which doesn't know version 2) refuses to
load it (`SchemaTooNew`) instead of overwriting it with the old shape. The player is asked to rejoin and can land on an
updated server.

If a migration only **adds** something that old servers can safely ignore, mark it `compat = "forward"`, and old servers
keep loading that data:

```lua
{
	version = 3,
	name = "remember the highest level",
	compat = "forward",
	up = function(data)
		data.highestLevel = data.level
		return data
	end,
},
```

### Trying migrations safely

`Retriever.dryRun` runs your migrations on sample data without touching any DataStore:

```lua
local report = Retriever.dryRun(store, { gold = 50, level = 3 }, { version = 1 })
print(report.ok, report.data.coins) --> true 50
```

The report has `ok`, the migrated copy in `data`, the steps that ran in `applied`, and on failure `kind`, `cause`,
`step` and `path`. To migrate saved data ahead of time, see `migrate` and `migrateAll` in the
[admin tools](#admin-tools).

---

## Schemas

A template only says what new data looks like. A **schema** also states the rules: which types, which ranges, how long.
Use one when you want Retriever to catch bad data early, such as a negative coin count, a misspelled field, or a name
that's too long.

```lua
local S = Retriever.schema

local store = Retriever.store("PlayerData", {
	schema = S.struct({
		coins = S.integer(0, { min = 0 }),
		level = S.integer(1, { min = 1, max = 100 }),
		nickname = S.string("", { maxLength = 20 }),
		inventory = S.map(S.boolean()),
		settings = S.struct({
			music = S.boolean(true),
			volume = S.number(0.5, { min = 0, max = 1 }),
		}),
		title = S.optional(S.string()),
		rank = S.enum({ "bronze", "silver", "gold" }),
	}),
	studio = "prefix",
})
```

Use **either** `template` **or** `schema`, not both. The schema gives the defaults: the first argument of each type is
its default value.

| Type | Example | Default if not given |
| --- | --- | --- |
| `S.number(default?, options?)` | `S.number(0.5, { min = 0, max = 1 })` | `0`, moved into the range |
| `S.integer(default?, options?)` | `S.integer(0, { min = 0 })` | `0`, moved into the range |
| `S.string(default?, options?)` | `S.string("", { maxLength = 20 })` | `""` |
| `S.boolean(default?)` | `S.boolean(true)` | `false` |
| `S.enum(values, default?)` | `S.enum({ "bronze", "silver", "gold" })` | the first value |
| `S.literal(value)` | `S.literal("sword")` | that value |
| `S.array(item, options?)` | `S.array(S.string(), { maxLength = 50 })` | `{}` |
| `S.map(value, options?)` | `S.map(S.integer(0), { maxSize = 200 })` | `{}` |
| `S.struct(fields, options?)` | `S.struct({ coins = S.integer(0) })` | each field's default |
| `S.optional(inner)` | `S.optional(S.string())` | missing (`nil`) |
| `S.any(default?)` | `S.any()` | the given default, else `nil` |
| `S.refine(inner, check, message?)` | `S.refine(S.integer(0), function(n) return n % 2 == 0 end, "must be even")` | `inner`'s default |

Options:

- **numbers**: `min`, `max`
- **strings**: `minLength`, `maxLength` (in characters), `pattern` (a Lua string pattern; use `^...$` to match the
  whole string)
- **arrays**: `minLength`, `maxLength`, `default`
- **maps** (dictionaries with string keys): `key` (a schema for the keys, like `S.string(nil, { pattern = "^%d+$" })`),
  `maxSize`, `default`
- **structs**: `extra = "keep"` (the default: fields the schema doesn't mention are kept and not checked) or
  `extra = "reject"`

When the rules are checked:

- **Every time data loads**, after migrations. Missing fields are filled in first.
- **On every save in Studio**, so mistakes show up while you test. Live servers skip this check when saving, to stay
  fast.

> If saved data breaks a rule, that player's data **fails to load** (`InvalidData`) until it's fixed. Use rules for what
> the data must be (types and sane limits), not for game balance you might change later, and check values in your own
> code before you change data.

---

## Testing in Studio

Studio can use the same DataStores as your live game, so a test session could load a real player's data, or your own,
and overwrite it. To prevent this, when Studio has API access, every store must say which data it uses:

- `studio = "prefix"`: Studio uses its **own separate copy** of the data (recommended). Nothing a test does reaches real
  players.
- `studio = "live"`: Studio uses the **real** data, on purpose. Retriever prints a warning.

```lua
local store = Retriever.store("PlayerData", {
	template = template,
	studio = "prefix",
})
```

If you leave it out, `Retriever.store` stops with an error that explains the choice. Live servers ignore this setting.

**Without API access** (it's turned off, or the place isn't published), Retriever uses an in-memory store instead.
Everything works, but nothing is kept after you stop testing, and a warning in the output says so.

**Extra checks.** In Studio, every save is also checked for values that DataStores can't store, and against your schema
if you have one, so you catch problems before they reach live servers (the `debug` setting).

---

## Settings

Everything `Retriever.store` accepts. You usually only need `template` (or `schema`) and `studio`:

```lua
local store = Retriever.store("PlayerData", {
	template = template,         -- or schema = S.struct({ ... })
	studio = "prefix",
	durability = "balanced",
	migrations = {},
	codec = Retriever.codec.lz,
})
```

| Setting | Default | What it does |
| --- | --- | --- |
| `template` | none | Data for new players. Missing fields are filled in from it on every load. |
| `schema` | none | Rules and defaults for the data, instead of `template`. See [Schemas](#schemas). |
| `studio` | none | `"prefix"` or `"live"`. Required in Studio when API access is on. See [Testing in Studio](#testing-in-studio). |
| `durability` | `"balanced"` | How often to save. See below. |
| `migrations` | none | Steps that update old data. See [Migrations](#migrations). |
| `scope` | none | A DataStore scope, to keep separate sets of data under one store name. |
| `codec` | none | How data is encoded when saved, like `Retriever.codec.lz` to compress it. See [Compression](#compression). |
| `ledger` | `{ max = 200, retention = 2592000 }` | How many `apply` ids each profile remembers, and for how many seconds (30 days). |
| `commands` | `{ inboxMax = 100, outboxMax = 100 }` | Limits for [commands](#sending-things-to-other-players). |
| `debug` | on in Studio only | Check every save for unstorable values and schema rules. |
| `snapshot` | `"reference"` | `"copy"` copies the data at every save. You won't normally need it. |

### How often data is saved

`durability` picks how quickly changes are saved:

| Preset | Changes are saved within | Lock lease |
| --- | --- | --- |
| `"economy"` | 5 minutes | 30 minutes |
| `"balanced"` (default) | 60 seconds | 15 minutes |
| `"strict"` | 15 seconds | 10 minutes |

- Profiles without changes aren't saved again, except now and then to renew their lock.
- Data is also saved when a player leaves, when the server shuts down, and whenever you call `commit`.
- The **lock lease** is how long a server's lock on a player's data lasts if it's never renewed. Running servers renew
  it automatically, so it only matters when a server crashes.
- Saving more often uses more of Roblox's DataStore request budget. `"balanced"` suits most games.

Or set the numbers yourself, in seconds:

```lua
durability = { autosave = 30, lease = 900, steal = 45 },
```

`autosave` can be 1 to 3600 seconds, and `lease` must be at least 60.

### When another server doesn't let go

If a player joins a server while another server still holds their data (for example, they rejoined quickly or
teleported), the new server asks the old one to save and release it. That normally takes a second or two.

If the old server doesn't answer within **45 seconds** (it froze, crashed, or can't reach the DataStore), the new server
**takes the data over**. Whatever the old server hadn't saved yet is thrown away; it can never overwrite the newer data.
You can change this with `steal`:

```lua
durability = { steal = false }, -- never take over: wait until the old lock expires (15 minutes by default)
durability = { steal = 20 },    -- take over after 20 seconds
```

> A join waits at most **90 seconds** before it gives up (the `timeout` option of
> [`Retriever.players`](#retrieverplayers-options)). If you set `steal` higher than that, raise `timeout` too, or the
> takeover never happens: `Retriever.players(store, { timeout = 150 })`.

---

## Errors

Functions that can fail during normal play **return a result** instead of throwing an error. Check `ok` first:

```lua
local result = profile:commit()
if not result.ok then
	warn(result.error.kind)    -- what went wrong, like "Unavailable"
	warn(result.error.message) -- what happened, with the store and key
	warn(result.error.hint)    -- what to do about it
end
```

Every error also has `retryable` (`true` when trying again later can work), `store`, `key`, and sometimes `cause`
(Roblox's original error text) and `details`. `Retriever.formatError(err)` turns an error into one line for logs.

Mistakes in your code, such as wrong arguments, editing a closed profile, or an invalid setting, **raise** an error
right away, with a message that explains the fix.

| Kind | What it means |
| --- | --- |
| `Unavailable` | Roblox's DataStores failed or were too busy, even after retries. Nothing changed. Trying again later can work. |
| `Unknown` | A save may or may not have gone through (Roblox's reply was lost). Calling `commit` again settles it. |
| `Locked` | Another server still holds this data and didn't release it in time. |
| `Corrupt` | The saved value isn't Retriever data (for example, other code saved it). It was left untouched. |
| `SchemaTooNew` | A newer version of your game saved this data. Normal during updates. It was left untouched. |
| `MigrationFailed` | A migration errored or produced invalid data. Nothing was saved. Fix the migration. |
| `InvalidData` | The data breaks a schema rule or contains something DataStores can't store. `error.details.path` says where, like `data.inventory.Sword`. |
| `TooLarge` | The data is over Roblox's 4 MB limit per key. |
| `Cancelled` | The load was cancelled, usually because the player left while it was loading. |
| `ShuttingDown` | The server is shutting down, so nothing new is loaded. |
| `AlreadyLoaded` | This key is already loaded on this server. Use `store:get(key)`. |
| `NotFound` | The key doesn't exist (only when you asked not to create it). |
| `OwnershipLost` | Another server took this data over. Changes since the last save won't be saved. |
| `Closed` | The profile is closing or closed. |
| `Conflict` | The data changed since you read it (only for operations that check a revision). |
| `InboxFull` | The target's command inbox is full. |
| `InvalidArgument` | A value you passed isn't valid. `error.details.what` says why. |
| `StudioApiDisabled` | Studio has no DataStore access. Turn on API access in Game Settings → Security. |

---

## More features

Everything below is optional. Skip it until you need it.

### Sending things to other players

A **command** is a message saved with a player's data, like a gift or a refund. You can send one to any player, **even
if they're offline or in another server**. It's applied exactly once: within moments if they're online, otherwise the
next time they join.

First, say what each kind of command does. Do this on every server, right after creating the store:

```lua
store:onCommand("gift", function(profile, payload, id)
	profile.data.coins += payload.coins
end)
```

Then send commands from anywhere on the server:

```lua
-- The key is the one Retriever.players uses: the player's user id as text.
local result = store:send(tostring(friendUserId), "gift", { coins = 100 })
if result.ok then
	print("Gift sent")
else
	warn("Gift failed:", result.error.message)
end
```

- Command handlers work like `apply`: change `profile.data` directly, don't yield, and check before changing anything.
  If a handler errors, the command stays saved and is tried again the next time that player's data loads.
- Pass an id to make retries safe: `store:send(key, "gift", payload, { id = "gift-" .. orderId })`. Sending the same id
  again doesn't add a second command (`result.duplicate` is `true`).
- Sending to a player who has never played creates a placeholder for them. Pass `{ create = false }` to get `NotFound`
  instead.
- A player's inbox holds up to 100 commands (the `commands` setting). Commands of a kind that has no handler wait until a
  server with a handler loads that player, so it's safe to send a new kind of command before every server is updated.

**Sending as part of a change.** Gifting coins from one player to another must take them from the sender and give them
to the friend, with no way to lose or copy them. `profile:enqueue` queues a command inside the sender's own profile. It's
sent only after the sender's change is saved, and if the server crashes before that, neither happens:

```lua
local function giftCoins(senderProfile, friendKey, amount)
	if senderProfile.data.coins < amount then
		return false
	end
	senderProfile:enqueue(friendKey, "gift", { coins = amount })
	senderProfile:edit(function(data)
		data.coins -= amount
	end)
	return true
end
```

Call `enqueue` before changing the data (it raises an error if it can't queue the command), and don't yield between the
two.

### Admin tools

`Retriever.admin(store)` gives you tools to look at and fix saved data, for example from an admin panel. Every function
yields and returns `{ ok = true, ... }` or `{ ok = false, error = ... }`. They're safe to use while the player is online:
Retriever never silently overwrites a server's unsaved changes.

```lua
local admin = Retriever.admin(store)
```

**Look at a player's data:**

```lua
local result = admin:inspect("123456")
if result.ok then
	local info = result.inspection
	print(info.status, info.revision, info.data)
	if info.owner and info.owner.live then
		print("Loaded right now on server", info.owner.jobId)
	end
end
```

`inspect` also reports the data's version, whether this server could load it (`loadable`), its size in bytes, waiting
commands, and the audit trail.

**Change a player's data**, online or offline:

```lua
local result = admin:edit("123456", {
	{ op = "increment", path = "coins", by = 500 },
	{ op = "set", path = "inventory.Sword", value = true },
}, { reason = "compensation for bug #42" })
```

Operations: `set` (with `value`), `remove`, `increment` (with `by`) and `insert` (adds `value` to the end of an array,
or at `index`). A path is a dotted string like `"settings.music"` or a list like `{ "items", 3 }`.

If the player is online somewhere, the edit is sent to that server and applied there exactly once
(`result.mode == "command"`). Otherwise it's written directly (`"direct"`). For bigger changes you can pass a function
instead, `function(data) ... end`; that only works while the player is offline, unless you pass `force = true`, which
takes the data over and throws away the online server's unsaved changes.

**Back up and copy data:**

```lua
local exported = admin:export("123456", { json = true })
-- exported.record is a plain table, exported.json is the same thing as text

admin:import(exported.record, { key = "654321" }) -- copy it to another key
```

`import` won't replace existing data unless you pass `onConflict = "overwrite"` (or `"skip"` to leave it alone).

**Restore an older version.** Roblox keeps old versions of each key for 30 days, about one per hour:

```lua
local list = admin:versions("123456", { limit = 20 })
for _, v in list.versions do
	print(v.version, os.date("!%Y-%m-%d %H:%M", v.time))
end

local preview = admin:previewRestore("123456", list.versions[2].version)
if preview.ok then
	for _, warning in preview.preview.warnings do
		warn(warning.message)
	end
	admin:restore(preview.preview, { reason = "player lost items" })
end
```

Always read the preview's warnings. For example, if the data was already saved this hour, Roblox has no backup of the
current version, so restoring would replace it for good. Export it first.

**Migrate data ahead of time:**

```lua
admin:migrate("123456") -- one key

local report = admin:migrateAll({ limit = 100 }) -- one page of keys
-- call it again with { cursor = report.cursor } until report.done is true
```

`admin:keys({ limit = 50 })` lists keys. Every admin change is recorded in the data's audit trail (the last 20 changes,
shown by `inspect`) and reported as an `admin` event.

> Only call admin tools from server code that checks the user is allowed to, for example against a list of admin user
> ids. Never let a RemoteEvent call them unchecked.

### Logging and monitoring

**Events** tell you what happens to your data, for logs or alerts:

```lua
Retriever.observe(store, function(event)
	if event.type == "loadFailed" or event.type == "writeFailed" or event.type == "unwritable" then
		warn("[Data]", event.type, event.key, event.error, event.cause)
	end
end)
```

| Event | When |
| --- | --- |
| `loaded` | A profile loaded (`seconds` is how long it took). |
| `loadFailed` | A load failed (`error`, `cause`). |
| `writeFailed` | One save attempt failed. Retriever tries again. |
| `unwritable` | The data can't be saved at all (`InvalidData` or `TooLarge`). |
| `handoffRequested` | Another server asked for this data, so this server releases it. |
| `ended` | A session ended (`reason`). |
| `commandFailed` | A command handler errored. The command is tried again later. |
| `admin` | An admin tool changed the data. |

Every event has `type`, `seq`, `store` and `time`, and when it applies `key`, `reason`, `error`, `cause`, `seconds`,
`revision` and `details`. `observe` returns a function that stops observing.

**History** keeps recent events in memory, which helps answer "what happened to this player's data?":

```lua
local history = Retriever.history(store)

for _, event in history:get("123456") do -- recent events of one key, oldest first
	print(event.type, event.reason, event.error)
end
local latest = history:recent(20) -- the store's last 20 events
```

It keeps 32 events for each of up to 256 keys, plus the store's last 256 events (options `perKey`, `keys` and
`capacity`). `history:stop()` frees the memory. While a history is on, `admin:inspect` includes the key's recent events.

**Metrics** are numbers for dashboards:

```lua
local m = Retriever.metrics()
print("sessions:", m.sessions, "failures:", m.failures, "load time p90 (s):", m.latency.load.p90)

local stats = store:stats() -- counters for one store
```

### Shared data: guilds and global settings

Player profiles belong to one server at a time. For data that **many servers** change, like a guild, a clan, or global
settings, use **documents**:

```lua
local guildStore = Retriever.store("Guilds", {
	template = { name = "", members = {} },
	studio = "prefix",
})
local guilds = Retriever.documents(guildStore)

-- Change a guild. Safe even when many servers do it at the same time.
local result = guilds:update("guild-42", function(data)
	data.members[tostring(player.UserId)] = true
end)

-- Read a guild.
local read = guilds:get("guild-42")
if read.ok then
	print(read.data.name, read.exists)
end
```

- The function you pass to `update` may run **more than once**: if another server changed the document at the same
  moment, Roblox runs it again on the newer data. Only change `data` inside it (no yields, nothing else). Change `data`
  in place, or return a new table.
- `get` returns a cached copy up to 5 seconds old. Pass `{ fresh = true }` to skip the cache. Treat `read.data` as
  read-only.
- `update` options: `revision` (apply only if the document is still at that revision, otherwise `Conflict`), `id`
  (makes retrying an `Unknown` result safe) and `create = false` (don't create missing documents).
- `Retriever.documents(store, { cacheTtl = 5, notify = true })`: with `notify = true`, servers tell each other when a
  document changes, so their cached copies refresh sooner.
- Use a separate store for documents. A key that's loaded as a player profile can't be used as a document.

Other methods: `peek(key)` (the cached copy, without waiting), `invalidate(key)`, `onChanged(fn)` and `destroy()`.

### Safe trades between players

A trade changes two players' data. If a server crashes halfway, a simple trade can lose items or copy them.
`Retriever.escrow` makes trades recoverable: either both players get the other's items, or both get their own items
back.

```lua
-- Create once at startup, on every server.
local trades = Retriever.escrow(store, {
	name = "items",

	-- Can this player give these items right now?
	validate = function(data, give)
		for _, item in give do
			if not data.inventory[item] then
				return false, "missing " .. item
			end
		end
		return true
	end,

	-- Take the items away (only called after validate said yes).
	debit = function(data, give)
		for _, item in give do
			data.inventory[item] = nil
		end
	end,

	-- Add items: the other player's, or this player's own items back if the trade is cancelled. Must never fail.
	credit = function(data, receive)
		for _, item in receive do
			data.inventory[item] = true
		end
	end,
})

-- When both players have accepted:
local result = trades:trade(profileA, { "Sword" }, profileB, { "Shield", "Bow" })
if result.ok then
	print("Trade complete")
else
	print("Trade didn't happen:", result.status, result.reason)
end
```

- Both players must be loaded on this server.
- `validate`, `debit` and `credit` must be quick, must not yield, and may only change `data`.
- If a server crashes in the middle of a trade, the trade is finished or undone automatically the next time the players
  load.
- `result.status` is one of `rejected`, `failed`, `pending`, `committed`, `completed`, `aborted`, `refunded` or
  `missing`. `trades:status(id)` looks up a trade by its id (`result.id`), and `trades:resume(id)` moves a stuck one
  forward.
- Recovery relies on the `ledger` setting: keep its `retention` (30 days by default) longer than a player might stay
  away after an interrupted trade.

### Compression

Roblox limits each key to 4 MB. If your profiles get big (huge inventories, saved builds), compress them:

```lua
local store = Retriever.store("PlayerData", {
	template = template,
	studio = "prefix",
	codec = Retriever.codec.lz,
})
```

Turning compression on or off later is safe: every save records how it was encoded. You can also add your own codec
with `Retriever.codec.register({ id = "mine", version = 1, encode = ..., decode = ... })`. Once data has been saved with
a codec, keep that codec (and version) registered, or that data can't be loaded.

### Loading data yourself

`Retriever.players` covers players in the server. To load any other key, use `store:load`, and close the profile when
you're done:

```lua
local result = store:load("some-key")
if result.ok then
	local profile = result.profile
	profile:edit(function(data)
		-- ...
	end)
	profile:close() -- saves and releases the lock
else
	warn(result.error.message)
end
```

Options: `timeout` (seconds to wait for locked data, default 90), `create` (default `true`), `cancel` (a function that
returns `true` to give up) and `userIds`.

---

## API reference

### `Retriever`

| Function | What it does |
| --- | --- |
| `Retriever.store(name, settings?)` | Creates a store. Call it once per name. |
| `Retriever.players(store, options?)` | Loads, saves and releases players' data automatically. |
| `Retriever.receipts(players, handlers, options?)` | Handles Developer Product purchases. |
| `Retriever.schema` | The schema builder (`S.struct`, `S.integer`, ...). |
| `Retriever.dryRun(storeOrSettings, value, options?)` | Tests loading and migrating data without any DataStore. |
| `Retriever.admin(store)` | Admin tools. |
| `Retriever.observe(store, fn)` | Calls `fn(event)` for every event. Returns a function that stops it. |
| `Retriever.history(store, options?)` | Keeps recent events in memory. |
| `Retriever.metrics()` | Counters, timings and queue sizes for all stores. |
| `Retriever.documents(store, options?)` | Shared data, like guilds or settings. |
| `Retriever.escrow(store, options)` | Recoverable trades. |
| `Retriever.codec` | `lz`, `identity`, `register(codec)` and `get(id, version?)`. |
| `Retriever.userKey(player, options?)` | The default key for a player. Options: `prefix` (like `"Player_"`) and `source = "userId"`. |
| `Retriever.validate(value)` | `true`, or `false` plus the reason a value can't be stored. |
| `Retriever.formatError(err)` | One line of text for an error. |
| `Retriever.Durability` | The `economy`, `balanced` and `strict` presets. |
| `Retriever.runtime(env, options?)` | Advanced: a separate Retriever with its own environment, for tests and tools (see the `Env` type in [Types.luau](src/Retriever/Types.luau)). |
| `Retriever.memoryProvider(time)` | Advanced: an in-memory DataStore provider for such an environment. |

### `Retriever.players` options

| Option | Default | What it does |
| --- | --- | --- |
| `onLoaded(player, profile)` | none | Called when a player's data is ready. May yield. |
| `onFailed(player, err)` | kicks the player | Called when the data couldn't be loaded. |
| `onEnded(player, reason, err)` | kicks the player | Called when the session ends while the player is still in the server. |
| `key(player)` | `Retriever.userKey(player)` | Returns the key a player's data is saved under. |
| `timeout` | `90` | Seconds to wait for data that's locked or unavailable. |
| `associateUserId` | `true` | Attach the player's UserId to their data, as Roblox recommends for privacy (GDPR) requests. |

The returned object has `players:get(player)`, `players:wait(player)` and `players:disconnect()`. `disconnect` stops
handling players; profiles that are already loaded stay open until `store:closeAll()`.

**Keys.** By default, a player's key is their user id as text, like `"123456"`. Retriever uses `player.User.Id` where
Roblox provides it, which is the same number as `player.UserId` for existing players. To add a prefix, like
`"Player_123456"`:

```lua
Retriever.players(store, {
	key = function(player)
		return Retriever.userKey(player, { prefix = "Player_" })
	end,
})
```

### Profile

| Member | What it does |
| --- | --- |
| `profile.data` | The data table. |
| `profile.key` | The key this data is saved under. |
| `profile.store` | The store it belongs to. |
| `profile.state` | `"active"`, `"closing"`, `"closed"` or `"lost"` (another server took over). |
| `profile:edit(fn)` | Changes the data. Saved automatically. |
| `profile:touch()` | Marks the profile as changed after you wrote to `profile.data` directly. |
| `profile:apply(id, fn)` | Runs `fn` once per id. Returns `"applied"` or `"duplicate"`. |
| `profile:commit(options?)` | Waits until saved. Option: `timeout` (30). Returns `{ ok = true, revision }` or `{ ok = false, error }`. |
| `profile:close(options?)` | Final save and release. Option: `timeout` (60). `Retriever.players` does this for you. |
| `profile:onEnded(fn)` | Calls `fn(reason, err)` once when the session ends. Returns a function that disconnects it. |
| `profile:isActive()` | `true` while the profile can be edited. |
| `profile:isDirty()` | `true` when there are unsaved changes. |
| `profile:revision()` | The revision of the last confirmed save. It goes up by one with every save. |
| `profile:addUserId(id)`, `profile:removeUserId(id)` | Changes which UserIds are attached to the data. |
| `profile:enqueue(key, kind, payload, options?)` | Sends a command after this profile's next save. Options: `id`, `store`. |

Why a session can end: `"closed"` (closed normally, for example the player left), `"shutdown"` (the server shut down),
`"released"` (handed over to another server that asked for it), `"ownershipLost"` (another server took it over, or the
data was deleted) and `"faulted"` (stopped after an internal error).

### Store

| Member | What it does |
| --- | --- |
| `store.name` | The store's name. |
| `store:load(key, options?)` | Loads a key yourself. See [Loading data yourself](#loading-data-yourself). |
| `store:get(key)` | The profile loaded on this server for that key, or `nil`. |
| `store:closeAll(timeout?)` | Saves and closes every profile of this store on this server. |
| `store:stats()` | Counters: sessions, requests, retries, failures, saves and more. |
| `store:onCommand(kind, handler)` | Sets what a kind of command does. |
| `store:send(key, kind, payload, options?)` | Sends a command to a key. Options: `id`, `create` (`true`), `timeout` (30). |
| `store:deliverOutbox(key)` | Sends the queued commands of a player who isn't loaded anywhere. Rarely needed. |

---

## Troubleshooting

**"refusing to open production data from Studio"**
Studio has API access and the store has no `studio` setting. Add `studio = "prefix"`. See
[Testing in Studio](#testing-in-studio).

**"DataStores are not available in this Studio session ... Data will NOT persist"**
Studio can't reach DataStores, so Retriever keeps data in memory. Publish the place and turn on **Enable Studio Access
to API Services** in **Game Settings → Security**.

**Players are kicked with "Your data could not be loaded, so you were removed to protect it. Please rejoin."**
The output shows a warning with the error kind:

- `Corrupt`: the DataStore holds data that Retriever didn't save, for example from ProfileStore or your old saving code.
  Retriever can't read other formats and leaves that data untouched. Use a new store name.
- `Locked`: another server still holds the data. This usually clears up by itself; see
  [When another server doesn't let go](#when-another-server-doesnt-let-go).
- `Unavailable`: Roblox's DataStores had problems. Check [status.roblox.com](https://status.roblox.com).
- `MigrationFailed` or `InvalidData`: a migration or a schema rule doesn't fit the saved data. `details.path` shows
  where.

**Players are kicked with "Your session ended because your data is being used by another server. Please rejoin."**
Another server took over this player's data, for example because this server stopped responding for a while. Progress
since the last save couldn't be saved here.

**Error: "edit() on profile ... after close() was called"**
Your code changed a profile after the player left. Check `profile:isActive()` before editing in code that can run late.

**Error: "a store named ... already exists"**
`Retriever.store` was called twice with the same name, for example from two scripts. Create it once in a ModuleScript
and require that module everywhere.

**Saves fail with `InvalidData`**
The data contains something DataStores can't store. The message says where, like
`data.spawnPoint: Vector3 cannot be stored`. See [Tips](#tips).

---

## Tips

- **Create each store once**, in a ModuleScript, and share it. Calling `Retriever.store` twice with the same name is an
  error.
- **Only save values DataStores accept:** tables, strings, numbers, booleans and buffers. No Instances, functions,
  `Vector3`, `CFrame`, `Color3` or other Roblox types. Convert them first, for example to `{ x = pos.X, y = pos.Y, z = pos.Z }`.
- **Use string keys in dictionaries:** `inventory.Sword = true` or `pets[tostring(petId)] = ...`. A number key like
  `inventory[12345] = true` turns the table into an array with holes, which can't be saved.
- **Arrays can't have holes:** `{ "a", "b", "c" }` is fine, `{ [1] = "a", [3] = "c" }` isn't. Don't mix number and
  string keys in one table either.
- **No `NaN` or infinite numbers.** Dividing by zero creates them.
- **Keep profiles small.** Roblox allows 4 MB per key, and smaller data saves faster. Use [compression](#compression) if
  you need more room.
- **Don't yield** inside `edit`, `apply`, purchase handlers, command handlers, document updates or trade functions.
- **Switching from another saving system?** Use a new store name. Retriever doesn't read data saved in other formats.
- **Fix `InvalidData` quickly.** The session keeps running, but if the player leaves before the data is fixed, their
  changes since the last successful save are lost (an error is logged).
- Store names, keys and scopes can be at most 50 characters long (a Roblox limit).

---

The source code is in [src/Retriever](src/Retriever). Each module starts with a comment explaining how it works, and
[init.luau](src/Retriever/init.luau) lists the full public API and its types.
