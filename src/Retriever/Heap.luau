--!strict
--!native
-- Binary min-heap keyed by `due`. Entries are caller-owned tables: the heap writes `heapIndex` into them, which makes
-- remove/reschedule O(log n) without a lookup table and without allocating per push.

export type Entry = {
	due: number,
	heapIndex: number, -- 0 when not in a heap
}

export type Heap = {
	size: number,
	items: { Entry },
}

local Heap = {}

function Heap.new(): Heap
	return { size = 0, items = {} }
end

local function siftUp(items: { Entry }, index: number)
	local entry = items[index]
	local due = entry.due
	while index > 1 do
		local parentIndex = index // 2
		local parent = items[parentIndex]
		if parent.due <= due then
			break
		end
		items[index] = parent
		parent.heapIndex = index
		index = parentIndex
	end
	items[index] = entry
	entry.heapIndex = index
end

local function siftDown(items: { Entry }, size: number, index: number)
	local entry = items[index]
	local due = entry.due
	while true do
		local child = index * 2
		if child > size then
			break
		end
		local childEntry = items[child]
		if child < size then
			local right = items[child + 1]
			if right.due < childEntry.due then
				child += 1
				childEntry = right
			end
		end
		if childEntry.due >= due then
			break
		end
		items[index] = childEntry
		childEntry.heapIndex = index
		index = child
	end
	items[index] = entry
	entry.heapIndex = index
end

function Heap.push(heap: Heap, entry: Entry)
	local size = heap.size + 1
	heap.size = size
	heap.items[size] = entry
	siftUp(heap.items, size)
end

function Heap.peek(heap: Heap): Entry?
	return heap.items[1]
end

local function removeAt(heap: Heap, index: number)
	local items = heap.items
	local size = heap.size
	local removed = items[index]
	removed.heapIndex = 0
	local last = items[size]
	items[size] = nil :: any
	heap.size = size - 1
	if index == size then
		return
	end
	items[index] = last
	last.heapIndex = index
	if index > 1 and items[index // 2].due > last.due then
		siftUp(items, index)
	else
		siftDown(items, size - 1, index)
	end
end

function Heap.pop(heap: Heap): Entry?
	if heap.size == 0 then
		return nil
	end
	local top = heap.items[1]
	removeAt(heap, 1)
	return top
end

-- Removes `entry` if it is in `heap`. Safe to call for entries that are not queued.
function Heap.remove(heap: Heap, entry: Entry)
	local index = entry.heapIndex
	if index > 0 and heap.items[index] == entry then
		removeAt(heap, index)
	end
end

-- Moves `entry` to a new due time, inserting it when it is not queued.
function Heap.reschedule(heap: Heap, entry: Entry, due: number)
	local index = entry.heapIndex
	if index > 0 and heap.items[index] == entry then
		local old = entry.due
		entry.due = due
		if due < old then
			siftUp(heap.items, index)
		elseif due > old then
			siftDown(heap.items, heap.size, index)
		end
	else
		entry.due = due
		Heap.push(heap, entry)
	end
end

function Heap.clear(heap: Heap)
	local items = heap.items
	for i = 1, heap.size do
		items[i].heapIndex = 0
		items[i] = nil :: any
	end
	heap.size = 0
end

return Heap
