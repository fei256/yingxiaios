//
//  CircularBuffer.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import Foundation

/// A locked ring buffer with optional frame ordering and bounded producers.
/// Seek generations reject callbacks that wake after a timeline flush.
public class CircularBuffer<Item: TimestampedQueueItem> {
    private var _buffer = ContiguousArray<Item?>()
//    private let semaphore = DispatchSemaphore(value: 0)
    private let condition = NSCondition()
    private var headIndex = UInt(0)
    private var tailIndex = UInt(0)
    private let expanding: Bool
    private let sorted: Bool
    private var destroyed = false
    private var _generation: UInt64 = 0
    var generation: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return _generation
    }

    @discardableResult func perform(ifGeneration generation: UInt64, _ body: () -> Void) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !destroyed, generation == _generation else { return false }
        body()
        return true
    }
    @inline(__always)
    private var _count: Int { Int(tailIndex &- headIndex) }
    @inline(__always)
    public var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return _count
    }

    private var _fps: Float = 24
    public internal(set) var fps: Float {
        get { condition.lock(); defer { condition.unlock() }; return _fps }
        set { condition.lock(); defer { condition.unlock() }; _fps = newValue }
    }
    @discardableResult func setFPS(_ value: Float, ifGeneration generation: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !destroyed, generation == _generation else { return false }
        _fps = value
        return true
    }
    private var _maxCount: Int
    public var maxCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return _maxCount
    }
    private var mask: UInt
    public init(initialCapacity: Int = 256, sorted: Bool = false, expanding: Bool = true) {
        self.expanding = expanding
        self.sorted = sorted
        let capacity = initialCapacity.nextPowerOf2()
        _buffer = ContiguousArray<Item?>(repeating: nil, count: Int(capacity))
        _maxCount = Int(capacity)
        mask = UInt(_maxCount - 1)
        assert(_buffer.count == capacity)
    }

    public func push(_ value: Item, generation: UInt64? = nil, accepting: (() -> Bool)? = nil) {
        condition.lock()
        defer { condition.unlock() }
        while !expanding && _count >= _maxCount && !destroyed {
            if let generation, generation != _generation { return }
            condition.wait()
        }
        guard !destroyed, generation == nil || generation == _generation,
              accepting?() != false else { return }
        if _buffer[Int(tailIndex & mask)] != nil {
            assertionFailure("value is not nil of headIndex: \(headIndex),tailIndex: \(tailIndex), bufferCount: \(_buffer.count), mask: \(mask)")
        }
        _buffer[Int(tailIndex & mask)] = value
        if sorted {
            // 不用sort进行排序，这个比较高效
            var index = tailIndex
            while index > headIndex {
                guard let item = _buffer[Int((index - 1) & mask)] else {
                    assertionFailure("value is nil of index: \((index - 1) & mask) headIndex: \(headIndex),tailIndex: \(tailIndex), bufferCount: \(_buffer.count),  mask: \(mask)")
                    break
                }
                if item.timestamp <= _buffer[Int(index & mask)]!.timestamp {
                    break
                }
                _buffer.swapAt(Int((index - 1) & mask), Int(index & mask))
                index -= 1
            }
        }
        tailIndex &+= 1
        if _count >= _maxCount {
            if expanding {
                // No more room left for another append so grow the buffer now.
                _doubleCapacity()
            }
        }
        // Producers and consumers share this condition. A single signal can
        // wake the wrong kind of waiter and leave an empty/full queue asleep.
        if _count == 1 { condition.broadcast() }
    }

    public func pop(wait: Bool = false, interrupted: (() -> Bool)? = nil,
                    where predicate: ((Item, Int) -> Bool)? = nil) -> Item? {
        condition.lock()
        defer { condition.unlock() }
        while headIndex == tailIndex, !destroyed {
            guard wait, interrupted?() != true else { return nil }
            condition.wait()
        }
        guard !destroyed else { return nil }
        let index = Int(headIndex & mask)
        guard let item = _buffer[index] else {
            assertionFailure("value is nil of index: \(index) headIndex: \(headIndex),tailIndex: \(tailIndex), bufferCount: \(_buffer.count), mask: \(mask)")
            return nil
        }
        if let predicate, !predicate(item, _count) {
            return nil
        } else {
            let wasFull = !expanding && _count == _maxCount
            headIndex &+= 1
            _buffer[index] = nil
            if wasFull { condition.broadcast() }
            return item
        }
    }

    public func wake() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    public func search(where predicate: (Item) -> Bool) -> [Item] {
        condition.lock()
        defer { condition.unlock() }
        let previousHead = headIndex
        var i = headIndex
        var result = [Item]()
        while i < tailIndex {
            if let item = _buffer[Int(i & mask)] {
                if predicate(item) {
                    result.append(item)
                    // Free every slot the head advances over, not only the match.
                    //
                    // Skipped items end up *behind* `headIndex`, so nothing reads
                    // them again — but leaving them non-nil permanently occupies
                    // their ring slot. After `initialCapacity` such leaks
                    // `tailIndex` wraps onto a still-occupied slot and `push`
                    // trips its "value is not nil" assertion.
                    //
                    // Reachable from ordinary playback: `FFmpegAssetTrack.search(for:)`
                    // matches only the subtitle cues due at the polled instant, so
                    // every cue stepped over leaks a slot. On a film with embedded
                    // subtitles the 255-slot queue fills within 10-15 minutes and
                    // the app traps on KSPlayer_MEPlayerItem_read.
                    while headIndex <= i {
                        _buffer[Int(headIndex & mask)] = nil
                        headIndex &+= 1
                    }
                }
            } else {
                assertionFailure("value is nil of index: \(i) headIndex: \(headIndex), tailIndex: \(tailIndex), bufferCount: \(_buffer.count), mask: \(mask)")
                return result
            }
            i += 1
        }
        if headIndex != previousHead { condition.broadcast() }
        return result
    }

    /// Samples timed cues without consuming cues that are still on screen. Expired cues are
    /// compacted out even when they overlap a longer active cue, releasing their ring slots.
    /// Ordinary `search(where:)` keeps its consuming behavior for its existing callers.
    public func search(inspecting inspect: ((Item) -> Void)? = nil,
                       removing expired: (Item) -> Bool, where predicate: (Item) -> Bool) -> [Item] {
        condition.lock()
        defer { condition.unlock() }
        // Observe the complete locked snapshot before discarding anything. A timed display
        // update can replace an indefinite predecessor even when that update already ended
        // before the first poll; dropping it first would lose the replacement boundary.
        if let inspect {
            for index in headIndex ..< tailIndex {
                if let item = _buffer[Int(index & mask)] { inspect(item) }
            }
        }
        var result = [Item]()
        var writeIndex = headIndex
        let previousTail = tailIndex
        for readIndex in headIndex ..< previousTail {
            let readSlot = Int(readIndex & mask)
            guard let item = _buffer[readSlot] else { continue }
            if expired(item) {
                _buffer[readSlot] = nil
                continue
            }
            if predicate(item) { result.append(item) }
            if writeIndex != readIndex {
                _buffer[Int(writeIndex & mask)] = item
                _buffer[readSlot] = nil
            }
            writeIndex &+= 1
        }
        tailIndex = writeIndex
        if writeIndex != previousTail { condition.broadcast() }
        return result
    }

    public func flush(advanceGeneration: Bool = false, updating update: (() -> Void)? = nil) {
        condition.lock()
        defer { condition.unlock() }
        if advanceGeneration { _generation &+= 1 }
        update?()
        headIndex = 0
        tailIndex = 0
        _buffer.removeAll(keepingCapacity: !destroyed)
        _buffer.append(contentsOf: ContiguousArray<Item?>(repeating: nil, count: destroyed ? 1 : _maxCount))
        condition.broadcast()
    }

    public func shutdown() {
        condition.lock()
        defer { condition.unlock() }
        guard !destroyed else { return }
        destroyed = true
        _generation &+= 1
        headIndex = 0
        tailIndex = 0
        _buffer = ContiguousArray<Item?>(repeating: nil, count: 1)
        condition.broadcast()
    }

    private func _doubleCapacity() {
        var newBacking: ContiguousArray<Item?> = []
        let newCapacity = _maxCount << 1 // Double the storage.
        precondition(newCapacity > 0, "Can't double capacity of \(_buffer.count)")
        assert(newCapacity % 2 == 0)
        newBacking.reserveCapacity(newCapacity)
        let head = Int(headIndex & mask)
        newBacking.append(contentsOf: _buffer[head ..< _maxCount])
        if head > 0 {
            newBacking.append(contentsOf: _buffer[0 ..< head])
        }
        let repeatitionCount = newCapacity &- newBacking.count
        newBacking.append(contentsOf: repeatElement(nil, count: repeatitionCount))
        headIndex = 0
        tailIndex = UInt(newBacking.count &- repeatitionCount)
        _buffer = newBacking
        _maxCount = newCapacity
        mask = UInt(_maxCount - 1)
    }
}

extension CircularBuffer: @unchecked Sendable where Item: Sendable {}

extension FixedWidthInteger {
    /// Returns the next power of two.
    @inline(__always)
    func nextPowerOf2() -> Self {
        guard self != 0 else {
            return 1
        }
        return 1 << (Self.bitWidth - (self - 1).leadingZeroBitCount)
    }
}
