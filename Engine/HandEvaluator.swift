import Foundation

// MARK: - Comparable hand score

struct HandScore: Comparable, Equatable {
    /// 0 = high card … 8 = straight flush, 9 = royal flush
    let category: Int
    let kickers: [Int]

    static func < (lhs: HandScore, rhs: HandScore) -> Bool {
        if lhs.category != rhs.category { return lhs.category < rhs.category }
        for (l, r) in zip(lhs.kickers, rhs.kickers) {
            if l != r { return l < r }
        }
        return lhs.kickers.count < rhs.kickers.count
    }
}

// MARK: - Evaluator

enum HandEvaluator {
  private static let rankValue: [Rank: Int] = {
      var map: [Rank: Int] = [:]
      for (i, rank) in Rank.allCases.enumerated() {
          map[rank] = i + 2
      }
      return map
  }()

  static func rankValue(_ rank: Rank) -> Int {
      rankValue[rank] ?? 0
  }

  /// Best hand from up to 7 cards (hole + board).
  static func evaluateBest(from cards: [Card]) -> (score: HandScore, rank: HandRank) {
      guard !cards.isEmpty else {
          return (HandScore(category: 0, kickers: []), .highCard)
      }
      if cards.count <= 5 {
          let score = evaluateFive(cards)
          return (score, handRank(for: score.category))
      }
      var best = evaluateFive(Array(cards.prefix(5)))
      for combo in combinations(cards, choose: 5) {
          let score = evaluateFive(combo)
          if score > best { best = score }
      }
      return (best, handRank(for: best.category))
  }

  static func handRank(for category: Int) -> HandRank {
      switch category {
      case 9: return .royalFlush
      case 8: return .straightFlush
      case 7: return .fourOfAKind
      case 6: return .fullHouse
      case 5: return .flush
      case 4: return .straight
      case 3: return .threeOfAKind
      case 2: return .twoPair
      case 1: return .pair
      default: return .highCard
      }
  }

  // MARK: - Five-card evaluation

  private static func evaluateFive(_ cards: [Card]) -> HandScore {
      let values = cards.map { rankValue($0.rank) }.sorted(by: >)
      let suits = cards.map(\.suit)
      let isFlush = Set(suits).count == 1
      let straightHigh = straightHighCard(values: values)
      let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
      let groups = counts.sorted {
          if $0.value != $1.value { return $0.value > $1.value }
          return $0.key > $1.key
      }

      if isFlush, let sh = straightHigh {
          if sh == 14 && values.contains(10) {
              return HandScore(category: 9, kickers: [14])
          }
          return HandScore(category: 8, kickers: [sh])
      }

      if let four = groups.first(where: { $0.value == 4 }) {
          let kicker = values.first { $0 != four.key } ?? 0
          return HandScore(category: 7, kickers: [four.key, kicker])
      }

      if let three = groups.first(where: { $0.value == 3 }),
         let pair = groups.first(where: { $0.value == 2 && $0.key != three.key }) {
          return HandScore(category: 6, kickers: [three.key, pair.key])
      }

      if isFlush {
          return HandScore(category: 5, kickers: values)
      }

      if let sh = straightHigh {
          return HandScore(category: 4, kickers: [sh])
      }

      if let three = groups.first(where: { $0.value == 3 }) {
          let kickers = values.filter { $0 != three.key }
          return HandScore(category: 3, kickers: [three.key] + kickers)
      }

      let pairs = groups.filter { $0.value == 2 }
      if pairs.count >= 2 {
          let highPair = pairs[0].key
          let lowPair = pairs[1].key
          let kicker = values.first { $0 != highPair && $0 != lowPair } ?? 0
          return HandScore(category: 2, kickers: [highPair, lowPair, kicker])
      }

      if let pair = groups.first(where: { $0.value == 2 }) {
          let kickers = values.filter { $0 != pair.key }
          return HandScore(category: 1, kickers: [pair.key] + kickers)
      }

      return HandScore(category: 0, kickers: values)
  }

  private static func straightHighCard(values: [Int]) -> Int? {
      let unique = Array(Set(values)).sorted(by: >)
      if unique.count < 5 { return nil }

      // Wheel: A-2-3-4-5
      if Set([14, 5, 4, 3, 2]).isSubset(of: Set(unique)) {
          return 5
      }

      for i in 0...(unique.count - 5) {
          let slice = Array(unique[i..<(i + 5)])
          if slice[0] - slice[4] == 4 && Set(slice).count == 5 {
              return slice[0]
          }
      }
      return nil
  }

  private static func combinations(_ cards: [Card], choose k: Int) -> [[Card]] {
      guard k > 0, cards.count >= k else { return [] }
      if k == 1 { return cards.map { [$0] } }
      if k == cards.count { return [cards] }

      var result: [[Card]] = []
      func build(start: Int, current: [Card]) {
          if current.count == k {
              result.append(current)
              return
          }
          let remaining = k - current.count
          for i in start...(cards.count - remaining) {
              build(start: i + 1, current: current + [cards[i]])
          }
      }
      build(start: 0, current: [])
      return result
  }
}
