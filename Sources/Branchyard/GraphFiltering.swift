import Foundation
import GitCore

extension GraphFilter {
    private static func key(_ repoPath: String) -> String { "graphFilter:" + repoPath }

    static func saved(for repoPath: String) -> GraphFilter {
        guard let data = UserDefaults.standard.data(forKey: key(repoPath)),
              let filter = try? JSONDecoder().decode(GraphFilter.self, from: data) else { return GraphFilter() }
        return filter
    }

    func save(for repoPath: String) {
        if isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key(repoPath))
        } else if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(repoPath))
        }
    }
}

/// How a branch shows in the graph.
enum GraphVisibility {
    case shown, hidden, soloed, outsideSolo
}

extension RepoModel {
    func visibility(of branch: Branch) -> GraphVisibility {
        if graphFilter.isSolo {
            if graphFilter.soloRefs.contains(branch.refName) { return .soloed }
            return branch.isCurrent ? .shown : .outsideSolo
        }
        return graphFilter.hides(branch.refName) && !branch.isCurrent ? .hidden : .shown
    }

    /// Branches the graph leaves out right now (not counting the current branch).
    var hiddenBranchCount: Int {
        branches.filter { !$0.isCurrent && graphFilter.hides($0.refName) }.count
    }

    func setGraphFilter(_ filter: GraphFilter) {
        guard filter != graphFilter else { return }
        graphFilter = filter
        filter.save(for: id)
        Task { await refresh() }
    }

    func hide(_ branches: [Branch]) {
        let refs = branches.filter { !$0.isCurrent }.map(\.refName)
        guard !refs.isEmpty else { return }
        var filter = graphFilter
        filter.soloRefs = []
        filter.hiddenRefs.formUnion(refs)
        setGraphFilter(filter)
    }

    func show(_ branch: Branch) {
        var filter = graphFilter
        filter.hiddenRefs.remove(branch.refName)
        if let remote = branch.remoteName, filter.hiddenRemotes.contains(remote) {
            // Showing one branch of a hidden remote: hide the others one by one instead.
            filter.hiddenRemotes.remove(remote)
            for other in branches where other.remoteName == remote && other.refName != branch.refName {
                filter.hiddenRefs.insert(other.refName)
            }
        }
        setGraphFilter(filter)
    }

    func setRemote(_ remote: String, hidden: Bool) {
        var filter = graphFilter
        filter.soloRefs = []
        if hidden {
            filter.hiddenRemotes.insert(remote)
        } else {
            filter.hiddenRemotes.remove(remote)
            filter.hiddenRefs = filter.hiddenRefs.filter { !$0.hasPrefix("refs/remotes/\(remote)/") }
        }
        setGraphFilter(filter)
    }

    func isRemoteHidden(_ remote: String) -> Bool { graphFilter.hiddenRemotes.contains(remote) }

    /// Shows only this branch (and the one you're on). With `adding`, keeps the other soloed branches.
    func solo(_ branches: [Branch], adding: Bool = false) {
        // A local branch brings its upstream along, so its remote label stays.
        let upstreams = branches.compactMap { $0.upstreamGone ? nil : $0.upstream.map { "refs/remotes/" + $0 } }
        let refs = Set(branches.map(\.refName) + upstreams)
        guard !refs.isEmpty else { return }
        var filter = graphFilter
        filter.soloRefs = adding ? filter.soloRefs.union(refs) : refs
        setGraphFilter(filter)
    }

    func unsolo(_ branches: [Branch]) {
        var filter = graphFilter
        filter.soloRefs.subtract(branches.map(\.refName))
        setGraphFilter(filter)
    }

    func exitSolo() {
        var filter = graphFilter
        filter.soloRefs = []
        setGraphFilter(filter)
    }

    /// "feature/x and main" — the soloed branches, for the graph's banner.
    var soloSummary: String {
        let soloed = branches.filter { graphFilter.soloRefs.contains($0.refName) }
        let upstreams = Set(soloed.compactMap(\.upstream))
        let names = soloed.filter { !($0.isRemote && upstreams.contains($0.name)) }.map(\.name).sorted()
        let shown = names.count > 3 ? Array(names.prefix(3)) + ["\(names.count - 3) more"] : names
        return ListFormatter.localizedString(byJoining: shown)
    }

    func showAllBranches() {
        setGraphFilter(GraphFilter())
    }

    /// Forgets branches and remotes that no longer exist, so a deleted branch can't keep the graph in solo.
    func pruneGraphFilter() {
        guard !graphFilter.isEmpty, !branches.isEmpty else { return }
        let live = Set(branches.map(\.refName))
        var filter = graphFilter
        filter.hiddenRefs.formIntersection(live)
        filter.soloRefs.formIntersection(live)
        filter.hiddenRemotes.formIntersection(remotes)
        setGraphFilter(filter)
    }
}
