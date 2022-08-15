import SwiftUI
import Combine

public typealias DestinationsWithTheirPaths<T> = [(T,[T])]

public class UIPilot<T: Equatable>: ObservableObject {

    private let logger: Logger
    private let viewGenerator: PathViewGenerator<T>

    @Published var paths: [UIPilotPath<T>] = []

    public var stack: [T] {
        return paths.map { $0.route }
    }

    public init(initial: T, debug: Bool = false, hideNavigationBar: Bool = false) {
        self.viewGenerator = PathViewGenerator<T>(hideNavigationBar: hideNavigationBar)
        logger = debug ? DebugLog() : EmptyLog()
        logger.log("UIPilot - Pilot Initialized.")

        viewGenerator.onPop = { [weak self] path in
            if let self = self, self.paths.count > 1
                && path.id == self.paths[self.paths.count - 2].id {
                    self.pop()
            }
        }

        push(initial)
    }

    public func push(_ route: T) {
        logger.log("UIPilot - Pushing \(route) route.")
        self.paths.append(UIPilotPath(route: route))
    }
    
    public func pushURL(
        _ url: URL,
        urlGuard: (URL) -> Bool = { _ in true },
        routeAndUrlMatcher: (URL, T) -> Bool,
        destinations: DestinationsWithTheirPaths<T>
    ) {
        guard urlGuard(url) else { return }
        destinations.forEach { path in
            let destination = path.0
            let pathViews = path.1
            if routeAndUrlMatcher(url, destination) {
                if !pathViews.isEmpty {
                    paths = []
                    paths = pathViews.map {
                        logger.log("UIPilot - Adding \($0) route to pathsViews.")
                        return UIPilotPath(route: $0)
                    }.reversed()
                }
                push(destination)
                return
            }
        }
    }

    public func pop() {
        if !self.paths.isEmpty {
            logger.log("UIPilot - Route popped.")
            self.paths.removeLast()
        }
    }

    public func popTo(_ route: T, inclusive: Bool = false) {
        logger.log("UIPilot: Popping route \(route).")

        if paths.isEmpty {
            logger.log("UIPilot - Path is empty.")
            return
        }

        guard var found = paths.firstIndex(where: { $0.route == route }) else {
            logger.log("UIPilot - Route not found.")
            return
        }

        if !inclusive {
            found += 1
        }

        let numToPop = (found..<paths.endIndex).count
        logger.log("UIPilot - Popping \(numToPop) routes")
        paths.removeLast(numToPop)
    }

    func getView(_ paths: [UIPilotPath<T>], _ routeMap: RouteMap<T>, _ pathViews: [UIPilotPath<T>: PathView]) -> (PathView?, [UIPilotPath<T>: PathView]) {
        return viewGenerator.generate(paths, routeMap, pathViews)
    }
}

struct UIPilotPath<T: Equatable>: Equatable, Hashable {
    let route: T
    let id: String = UUID().uuidString

    static func == (lhs: UIPilotPath, rhs: UIPilotPath) -> Bool {
        return lhs.route == rhs.route && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct PathView: View {
    private let content: AnyView
    private let hideNavigationBar: Bool
    @ObservedObject var state: PathViewState

    public init(_ content: AnyView, state: PathViewState, hideNavigationBar: Bool = false) {
        self.content = content
        self.state = state
        self.hideNavigationBar = hideNavigationBar
    }

    var body: some View {
        VStack {
            NavigationLink(destination: self.state.next, isActive: self.$state.isActive) {
                EmptyView()
            }
#if os(iOS)
            .isDetailLink(false)
#endif
            content
#if os(iOS)
            .navigationBarHidden(self.hideNavigationBar)
#endif
        }
    }
}

class PathViewState: ObservableObject {
    @Published
    var isActive: Bool = false {
        didSet {
            if !isActive && next != nil {
                onPop()
            }
        }
    }

    @Published
    var next: PathView? {
        didSet {
            isActive = next != nil
        }
    }

    var onPop: () -> Void

    init(next: PathView? = nil, onPop: @escaping () -> Void = {}) {
        self.next = next
        self.onPop = onPop
    }
}

class PathViewGenerator<T: Equatable> {

    private let hideNavigationBar: Bool
    var onPop: ((UIPilotPath<T>) -> Void)?

    init(hideNavigationBar: Bool = false) {
        self.hideNavigationBar = hideNavigationBar
    }
    
    func generate(_ paths: [UIPilotPath<T>], _ routeMap: RouteMap<T>, _ pathViews: [UIPilotPath<T>: PathView]) -> (PathView?, [UIPilotPath<T>: PathView]) {
        var pathViews = recycleViews(paths, pathViews: pathViews)

        var current: PathView?
        for path in paths.reversed() {
            var content = pathViews[path]

            if content == nil {
                pathViews[path] = PathView(
                    routeMap(path.route),
                    state: PathViewState(),
                    hideNavigationBar: hideNavigationBar
                )
                content = pathViews[path]
            }

            content?.state.next = current
            content?.state.onPop = current == nil ? {} : { [weak self] in
                if let self = self {
                    self.onPop?(path)
                }
            }
            current = content
        }
        return (current, pathViews)
    }

    private func recycleViews(_ paths: [UIPilotPath<T>], pathViews: [UIPilotPath<T>: PathView]) -> [UIPilotPath<T>: PathView] {
        var pathViews = pathViews
        for key in pathViews.keys {
            if !paths.contains(key) {
                pathViews.removeValue(forKey: key)
            }
        }
        return pathViews
    }
}

public typealias RouteMap<T> = (T) -> AnyView

public struct UIPilotHost<T: Equatable>: View {

    @ObservedObject
    private var pilot: UIPilot<T>

    private let routeMap: RouteMap<T>

    @State
    var pathViews = [UIPilotPath<T>: PathView]()
    @State
    var content: PathView?

    public init(_ pilot: UIPilot<T>, _ routeMap: @escaping RouteMap<T>) {
        self.pilot = pilot
        self.routeMap = routeMap
    }

    public var body: some View {
        NavigationView {
            content
        }
#if !os(macOS)
        .navigationViewStyle(.stack)
#endif
        .environmentObject(pilot)
        .onReceive(pilot.$paths) { paths in
            let (newContent, newPathViews) = pilot.getView(paths, routeMap, pathViews)
            self.content = newContent
            self.pathViews = newPathViews
        }
    }
}

protocol Logger {
    func log(_ value: String)
}
