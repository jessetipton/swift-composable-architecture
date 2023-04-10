import Combine
import Foundation
import OrderedCollections

public struct StackElementID: Hashable, Sendable {
  @_spi(Internals) public var generation: Int
  @_spi(Internals) public var rawValue: AnyHashableSendable

  @_spi(Internals) public init<RawValue: Hashable & Sendable>(generation: Int, rawValue: RawValue) {
    self.generation = generation
    self.rawValue = AnyHashableSendable(rawValue)
  }
}

extension StackElementID: CustomDebugStringConvertible {
  public var debugDescription: String {
    "#\(self.generation)"
  }
}

extension StackElementID: CustomDumpStringConvertible {
  public var customDumpDescription: String {
    self.debugDescription
  }
}

extension StackElementID: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) {
    #if DEBUG
      @Dependency(\.context) var context
      if context != .test {
        runtimeWarn(
          """
          Specifying stack element IDs by integer literal is not allowed outside of tests.

          In tests, integer literal stack element IDs can be used as a shorthand to the \
          auto-incrementing generation of the current dependency context. This can be useful when \
          asserting against actions received by a specific element.
          """
        )
      }
    #endif
    self.init(generation: value, rawValue: value)
  }
}

@_spi(Internals) public struct StackElementIDGenerator: DependencyKey, Sendable {
  public let next: @Sendable () -> StackElementID
  public let peek: @Sendable () -> StackElementID

  func callAsFunction() -> StackElementID {
    self.next()
  }

  public static var liveValue: Self {
    let next = LockIsolated(StackElementID(generation: 0, rawValue: UUID()))
    return Self(
      next: {
        defer {
          next.withValue { $0 = StackElementID(generation: $0.generation + 1, rawValue: UUID()) }
        }
        return next.value
      },
      peek: { next.value }
    )
  }

  public static var testValue: Self {
    let next = LockIsolated(StackElementID(generation: 0, rawValue: 0))
    return Self(
      next: {
        defer {
          next.withValue {
            $0 = StackElementID(generation: $0.generation + 1, rawValue: $0.generation + 1)
          }
        }
        return next.value
      },
      peek: { next.value }
    )
  }

  func incrementingCopy() -> Self {
    let peek = self.peek()
    let next = LockIsolated(StackElementID(generation: peek.generation, rawValue: peek.generation))
    return Self(
      next: {
        defer {
          next.withValue {
            $0 = StackElementID(generation: $0.generation + 1, rawValue: $0.generation + 1)
          }
        }
        return next.value
      },
      peek: { next.value }
    )
  }
}

extension DependencyValues {
  @_spi(Internals) public var stackElementID: StackElementIDGenerator {
    get { self[StackElementIDGenerator.self] }
    set { self[StackElementIDGenerator.self] = newValue }
  }
}

public struct StackState<Element>: RandomAccessCollection {
  private var _dictionary: OrderedDictionary<StackElementID, Element>
  fileprivate var _mounted: Set<StackElementID> = []

  @Dependency(\.stackElementID) private var stackElementID

  var _ids: OrderedSet<StackElementID> {
    self._dictionary.keys
  }

  public var ids: [StackElementID] {
    self._dictionary.keys.elements
  }

  public init() {
    self._dictionary = [:]
  }

  public subscript(id id: StackElementID) -> Element? {
    _read { yield self._dictionary[id] }
    _modify {
      // TODO: Prevent insertions and runtime warn when an insertion is attempted
      yield &self._dictionary[id]
      if !self._dictionary.keys.contains(id) {
        self._mounted.remove(id)
      }
    }
  }

  // TODO: Think about this
//  public func id(after id: StackElementID) -> StackElementID? {
//    guard
//      let current = self._dictionary.keys.firstIndex(of: id),
//      let next = self._dictionary.keys.index(
//        current, offsetBy: 1, limitedBy: self._dictionary.keys.endIndex
//      )
//    else { return nil }
//    return self._dictionary.keys[next]
//  }
//
//  public func id(before id: StackElementID) -> StackElementID? {
//    guard
//      let current = self._dictionary.keys.firstIndex(of: id),
//      let previous = self._dictionary.keys.index(
//        current, offsetBy: -1, limitedBy: self._dictionary.keys.endIndex
//      )
//    else { return nil }
//    return self._dictionary.keys[previous]
//  }

  @discardableResult
  public mutating func pop(from id: StackElementID) -> Bool {
    guard let index = self._dictionary.keys.firstIndex(of: id)
    else { return false }
    for id in self._dictionary.keys[index...] {
      self._mounted.remove(id)
    }
    self._dictionary.removeSubrange(index...)
    return true
  }

  @discardableResult
  public mutating func pop(to id: StackElementID) -> Bool {
    guard var index = self._dictionary.keys.firstIndex(of: id)
    else { return false }
    index += 1
    for id in self._dictionary.keys[index...] {
      self._mounted.remove(id)
    }
    self._dictionary.removeSubrange(index...)
    return true
  }

  public var startIndex: Int { self._dictionary.keys.startIndex }

  public var endIndex: Int { self._dictionary.keys.endIndex }

  public func index(after i: Int) -> Int { self._dictionary.keys.index(after: i) }

  public func index(before i: Int) -> Int { self._dictionary.keys.index(before: i) }

  public subscript(position: Int) -> Element { self._dictionary.values[position] }

  public mutating func append(_ element: Element) {
    self._dictionary[self.stackElementID.next()] = element
  }

  public mutating func append<S: Sequence>(contentsOf elements: S) where S.Element == Element {
    self._dictionary.reserveCapacity(self._dictionary.count + elements.underestimatedCount)
    for element in elements {
      self.append(element)
    }
  }

  public func appending(_ element: Element) -> Self {
    var stack = self
    stack.append(element)
    return stack
  }

  public func appending<S: Sequence>(contentsOf elements: S) -> Self where S.Element == Element {
    var stack = self
    stack.append(contentsOf: elements)
    return stack
  }

  public mutating func insert(_ newElement: Element, at i: Index) {
    self._dictionary.updateValue(newElement, forKey: self.stackElementID.next(), insertingAt: i)
  }

  @discardableResult
  public mutating func removeLast() -> Element {
    let element = self._dictionary.removeLast()
    self._mounted.remove(element.key)
    return element.value
  }

  public mutating func removeLast(_ n: Int) {
    for _ in 1...n {
      self._dictionary.removeLast()
    }
  }

  public mutating func removeAll() {
    self._dictionary.removeAll()
    self._mounted.removeAll()
  }

  public func dropLast(_ n: Int = 1) -> Self {
    var stack = self
    stack.removeLast(Swift.min(stack.count, n))
    return stack
  }

  var path: PathView {
    _read { yield PathView(base: self) }
//    get { PathView(base: self) }
    _modify {
      var path = PathView(base: self)
      yield &path
      self = path.base
    }
    set { self = newValue.base }
  }

  struct PathView: MutableCollection, RandomAccessCollection, RangeReplaceableCollection {
    var base: StackState

    var startIndex: Int { self.base.startIndex }
    var endIndex: Int { self.base.endIndex }
    func index(after i: Int) -> Int { self.base.index(after: i) }
    func index(before i: Int) -> Int { self.base.index(before: i) }

    subscript(position: Int) -> Component<Element> {
      _read {
        let (id, element) = self.base._dictionary.elements[position]
        yield Component(id: id, element: element)
      }
//      get {
//        let (id, element) = self.base._dictionary.elements[position]
//        return Component(id: id, element: element)
//      }
      _modify {
        let (id, element) = self.base._dictionary.elements[position]
        var component = Component(id: id, element: element)
        yield &component
        self.base._dictionary[id] = component.element
      }
      set {
        self.base._dictionary[newValue.id] = newValue.element
      }
    }

    init(base: StackState) {
      self.base = base
    }

    init() {
      self.init(base: StackState())
    }

    mutating func replaceSubrange<C: Collection>(
      _ subrange: Range<Int>, with newElements: C
    ) where C.Element == Component<Element> {
      for id in self.base._ids[subrange] {
        self.base._mounted.remove(id)
      }
      self.base._dictionary.removeSubrange(subrange)
      for component in newElements.reversed() {
        self.base._dictionary
          .updateValue(component.element, forKey: component.id, insertingAt: subrange.lowerBound)
      }
    }
  }
}

struct Component<Element>: Hashable {
  let id: StackElementID
  var element: Element

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(self.id)
  }
}

extension StackState: Equatable where Element: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.elementsEqual(rhs)
  }
}

extension StackState: Hashable where Element: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.count)
    for id in self.ids {
      hasher.combine(self[id: id])
    }
  }
}

// NB: We can remove `@unchecked` when swift-collections 1.1 is released.
extension StackState: @unchecked Sendable where Element: Sendable {}

extension StackState: Decodable where Element: Decodable {
  public init(from decoder: Decoder) throws {
    let elements = try [Element](from: decoder)
    self.init()
    self.append(contentsOf: elements)
  }
}

extension StackState: Encodable where Element: Encodable {
  public func encode(to encoder: Encoder) throws {
    try [Element](self).encode(to: encoder)
  }
}

// TODO: revisit
//extension StackState: CustomStringConvertible {
//  public var description: String {
//    self._dictionary.values.elements.description
//  }
//}
//
//extension StackState: CustomDebugStringConvertible {
//  public var debugDescription: String {
//    self._dictionary.values.elements.debugDescription
//  }
//}

extension StackState: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, unlabeledChildren: Array(zip(self.ids, self)), displayStyle: .dictionary)
  }
}

// TODO: Is this even worth it?
//public typealias StackStateOf<R: ReducerProtocol> = StackState<R.State/*, _???*/>

public enum StackAction<State, Action> {
  case _popFrom(id: StackElementID)
  case element(id: StackElementID, action: Action)
  case setPath(StackState<State>)
}

//public typealias StackActionOf<R: ReducerProtocol> = StackAction<R.State, R.Action>

extension StackAction: Equatable where State: Equatable, Action: Equatable {}
extension StackAction: Hashable where State: Hashable, Action: Hashable {}

extension ReducerProtocol {
  public func forEach<DestinationState, DestinationAction, Destination: ReducerProtocol>(
    _ toStackState: WritableKeyPath<State, StackState<DestinationState>>,
    action toStackAction: CasePath<Action, StackAction<DestinationState, DestinationAction>>,
    @ReducerBuilder<DestinationState, DestinationAction> destination: () -> Destination,
    file: StaticString = #file,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) -> _StackReducer<Self, Destination>
  where Destination.State == DestinationState, Destination.Action == DestinationAction {
    _StackReducer(
      base: self,
      toStackState: toStackState,
      toStackAction: toStackAction,
      destination: destination(),
      file: file,
      fileID: fileID,
      line: line
    )
  }
}

public struct _StackReducer<
  Base: ReducerProtocol, Destination: ReducerProtocol
>: ReducerProtocol {
  let base: Base
  let toStackState: WritableKeyPath<Base.State, StackState<Destination.State>>
  let toStackAction: CasePath<Base.Action, StackAction<Destination.State, Destination.Action>>
  let destination: Destination
  let file: StaticString
  let fileID: StaticString
  let line: UInt

  @Dependency(\.navigationIDPath) var navigationIDPath

  public func reduce(into state: inout Base.State, action: Base.Action) -> EffectTask<Base.Action> {
    let idsBefore = state[keyPath: self.toStackState]._ids
    let destinationEffects: EffectTask<Base.Action>
    let baseEffects: EffectTask<Base.Action>

    switch (self.toStackAction.extract(from: action)) {
    case let .element(elementID, destinationAction):
      if state[keyPath: self.toStackState][id: elementID] != nil {
        let elementNavigationIDPath = self.navigationIDPath(for: elementID)
        destinationEffects = self.destination
          .dependency(
            \.dismiss,
             DismissEffect { @MainActor in
               Task._cancel(
                id: NavigationDismissID(elementID: elementID),
                navigationID: elementNavigationIDPath
               )
             }
          )
          .dependency(\.navigationIDPath, elementNavigationIDPath)
          .reduce(
            into: &state[keyPath: self.toStackState][id: elementID]!,
            action: destinationAction
          )
          .map { toStackAction.embed(.element(id: elementID, action: $0)) }
          ._cancellable(navigationIDPath: elementNavigationIDPath)
      } else {
        runtimeWarn("TODO")
        destinationEffects = .none
      }

      baseEffects = self.base.reduce(into: &state, action: action)

    case let ._popFrom(id):
      destinationEffects = .none
      baseEffects = self.base.reduce(into: &state, action: action)
      var stack = state[keyPath: self.toStackState]
      if !stack.pop(from: id) {
        runtimeWarn("TODO")
      }
      return .send(self.toStackAction.embed(.setPath(stack)))

    case let .setPath(stack):
      destinationEffects = .none
      baseEffects = self.base.reduce(into: &state, action: action)
      state[keyPath: self.toStackState] = stack

    case .none:
      destinationEffects = .none
      baseEffects = self.base.reduce(into: &state, action: action)
    }

    let idsAfter = state[keyPath: self.toStackState]._ids
    let idsMounted = state[keyPath: self.toStackState]._mounted

    let cancelEffects: EffectTask<Base.Action> =
      areOrderedSetsDuplicates(idsBefore, idsAfter)
      ? .none
      : .merge(
        idsBefore.subtracting(idsAfter).map {
          ._cancel(navigationID: self.navigationIDPath(for: $0))
        }
      )
    let presentEffects: EffectTask<Base.Action> =
      idsAfter.count == idsMounted.count
      ? .none
      : .merge(
        idsAfter.subtracting(idsMounted).map { elementID in
          let navigationDestinationID = self.navigationIDPath(for: elementID)
          state[keyPath: self.toStackState]._mounted.insert(elementID)
          return Empty(completeImmediately: false)
            .eraseToEffect()
            ._cancellable(
              id: NavigationDismissID(elementID: elementID),
              navigationIDPath: navigationDestinationID
            )
            .append(Just(self.toStackAction.embed(._popFrom(id: elementID))))
            .eraseToEffect()
            ._cancellable(navigationIDPath: navigationDestinationID)
            ._cancellable(id: OnFirstAppearID(), navigationIDPath: .init())
        }
      )

    return .merge(
      destinationEffects,
      baseEffects,
      cancelEffects,
      presentEffects
    )
  }

  private func navigationIDPath(for elementID: StackElementID) -> NavigationIDPath {
    self.navigationIDPath.appending(
      NavigationID(
        id: elementID,
        keyPath: self.toStackState
      )
    )
  }
}

private struct NavigationDismissID: Hashable {
  let elementID: AnyHashable  // TODO: rename
}
