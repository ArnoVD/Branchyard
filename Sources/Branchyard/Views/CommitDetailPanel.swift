import SwiftUI
import GitCore

/// Right pane while a commit is picked in the graph: message, author, parents, changed files.
struct CommitDetailPanel: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        VStack(spacing: 0) {
            if let detail = model.commitDetail {
                header(detail.commit)
                Divider()
                info(detail)
                Divider()
                files(detail)
            } else {
                HStack {
                    Spacer()
                    closeButton
                }
                .padding(10)
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var closeButton: some View {
        Button {
            model.selectCommit(nil)
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Close commit details")
    }

    private func header(_ commit: Commit) -> some View {
        HStack(spacing: 8) {
            Text("commit:").foregroundStyle(.secondary)
            Text(commit.shortSHA)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            Button {
                model.copyToPasteboard(commit.sha, what: "Commit SHA \(commit.shortSHA)")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy full SHA")
            Spacer()
            closeButton
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.byPanel)
    }

    private func info(_ detail: CommitDetail) -> some View {
        let commit = detail.commit
        let lines = detail.body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let subject = lines.first.map(String.init) ?? commit.subject
        let body = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(subject)
                    .font(.system(size: 14, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !body.isEmpty {
                    Text(body)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Text(commit.initials)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(laneColor(commit)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(commit.author).font(.system(size: 12, weight: .semibold))
                        Text("authored \(commit.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .help(commit.email)

                HStack(spacing: 6) {
                    Text(commit.parents.count > 1 ? "parents:" : "parent:")
                        .foregroundStyle(.secondary)
                    if commit.parents.isEmpty {
                        Text("none (first commit)").foregroundStyle(.tertiary)
                    }
                    ForEach(commit.parents, id: \.self) { parent in
                        Button(String(parent.prefix(7))) { model.selectCommit(parent, scroll: true) }
                            .buttonStyle(.link)
                            .font(.system(size: 12, design: .monospaced))
                            .help("Go to \(parent)")
                    }
                }
                .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(minHeight: 120, idealHeight: 190, maxHeight: 280)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func laneColor(_ commit: Commit) -> Color {
        LaneColors.color(model.graph.first { $0.commit.sha == commit.sha }?.color ?? 0)
    }

    private func files(_ detail: CommitDetail) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Changed Files").font(.subheadline.weight(.semibold))
                Text("\(detail.files.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
                if detail.commit.isMerge {
                    Text("vs. first parent").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.byPanel)
            Divider()
            List(selection: $model.selectedCommitFileID) {
                ForEach(detail.files) { file in
                    CommitFileRow(file: file).tag(file.id)
                }
            }
            .listStyle(.inset)
            .overlay {
                if detail.files.isEmpty {
                    Text("No file changes").foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct CommitFileRow: View {
    let file: CommitFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.kind.letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(file.kind.tint))
            VStack(alignment: .leading, spacing: 0) {
                Text(file.fileName).lineLimit(1)
                if let detail = file.originalPath.map({ "from \($0)" }) ?? (file.directory.isEmpty ? nil : file.directory) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .help(file.path)
    }
}

extension ChangeKind {
    var tint: Color {
        switch self {
        case .added, .untracked: return .green
        case .deleted: return .red
        case .conflicted: return .orange
        case .renamed, .copied: return .purple
        default: return .blue
        }
    }
}
