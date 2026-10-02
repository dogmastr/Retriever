--!strict
-- Allocation-free FIFO ring buffer (array part only, grows by doubling, never shrinks). Used for per-key lane queues and
-- dispatcher priority queues where `table.remove(t, 1)` would be O(n).

export type Ring<T> = {
	head: number, -- index of the next item to pop
	count: number,
	cap: number,
	items: { T? },
}

local Ring = {}

function Ring.new<T>(): Ring<T>
	return { head = 1, count = 0, cap = 4, items = table.create(4) }
end

function Ring.push<T>(ring: Ring<T>, value: T)
	local cap = ring.cap
	if ring.count == cap then
		-- grow: unroll into a new array so head becomes 1 again
		local old = ring.items
		local new: { T? } = table.create(cap * 2)
		local head = ring.head
		for i = 1, ring.count do
			local index = head + i - 1
			if index > cap then
				index -= cap
			end
			new[i] = old[index]
		end
		ring.items = new
		ring.head = 1
		ring.cap = cap * 2
		cap = ring.cap
	end
	local tail = ring.head + ring.count
	if tail > cap then
		tail -= cap
	end
	ring.items[tail] = value
	ring.count += 1
end

function Ring.pop<T>(ring: Ring<T>): T?
	if ring.count == 0 then
		return nil
	end
	local head = ring.head
	local value = ring.items[head]
	ring.items[head] = nil
	head += 1
	if head > ring.cap then
		head = 1
	end
	ring.head = head
	ring.count -= 1
	return value
end

function Ring.peek<T>(ring: Ring<T>): T?
	if ring.count == 0 then
		return nil
	end
	return ring.items[ring.head]
end

function Ring.clear<T>(ring: Ring<T>)
	while ring.count > 0 do
		Ring.pop(ring)
	end
end

return Ring
