import Foundation

actor MediaMemoryCache {
    struct Statistics: Sendable, Equatable {
        let entryCount: Int
        let costBytes: Int
    }

    private final class Node {
        let key: String
        var value: MediaImage
        var cost: Int
        weak var previous: Node?
        var next: Node?

        init(key: String, value: MediaImage, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private let budgetBytes: Int
    private var nodes: [String: Node] = [:]
    private var mostRecent: Node?
    private var leastRecent: Node?
    private var totalCost = 0

    init(budgetBytes: Int) {
        self.budgetBytes = max(1, budgetBytes)
    }

    func image(for key: String) -> MediaImage? {
        guard let node = nodes[key] else { return nil }
        moveToFront(node)
        return node.value.delivered(from: .memoryCache)
    }

    func insert(_ image: MediaImage, for key: String) {
        guard !Task.isCancelled else { return }
        let cost = image.decodedCostBytes
        guard cost <= budgetBytes else {
            removeValue(for: key)
            return
        }
        if let existing = nodes[key] {
            totalCost -= existing.cost
            existing.value = image.delivered(from: .generated)
            existing.cost = cost
            totalCost += cost
            moveToFront(existing)
        } else {
            let node = Node(key: key, value: image.delivered(from: .generated), cost: cost)
            nodes[key] = node
            insertAtFront(node)
            totalCost += cost
        }
        evictIfNeeded()
    }

    func removeAll() {
        nodes.removeAll(keepingCapacity: false)
        mostRecent = nil
        leastRecent = nil
        totalCost = 0
    }

    func removeValue(for key: String) {
        guard let node = nodes.removeValue(forKey: key) else { return }
        detach(node)
        totalCost = max(0, totalCost - node.cost)
    }

    func trim(to budget: Int) {
        let target = max(0, min(budgetBytes, budget))
        while totalCost > target, let victim = leastRecent {
            removeValue(for: victim.key)
        }
    }

    func statistics() -> Statistics {
        Statistics(entryCount: nodes.count, costBytes: totalCost)
    }

    private func evictIfNeeded() {
        while totalCost > budgetBytes, let victim = leastRecent {
            removeValue(for: victim.key)
        }
    }

    private func moveToFront(_ node: Node) {
        guard mostRecent !== node else { return }
        detach(node)
        insertAtFront(node)
    }

    private func insertAtFront(_ node: Node) {
        node.previous = nil
        node.next = mostRecent
        mostRecent?.previous = node
        mostRecent = node
        if leastRecent == nil { leastRecent = node }
    }

    private func detach(_ node: Node) {
        let previous = node.previous
        let next = node.next
        previous?.next = next
        next?.previous = previous
        if mostRecent === node { mostRecent = next }
        if leastRecent === node { leastRecent = previous }
        node.previous = nil
        node.next = nil
    }
}
