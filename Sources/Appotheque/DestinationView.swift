import LauncherCore
import SwiftUI

/// Simulator or paired device for an iOS app. Shown as a sheet before a first launch, as a popover from the detail.
struct DestinationPicker: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let request: DestinationRequest
    @State private var kind: LaunchDestination.Kind = .simulator
    @State private var selectedID: String?
    @State private var query = ""

    private var matches: [LaunchDestination] {
        model.destinations.filter { $0.kind == kind && (query.isEmpty || $0.label.localizedStandardContains(query)) }
    }
    private var selected: LaunchDestination? { matches.first { $0.id == selectedID } }
    private func reason(_ destination: LaunchDestination) -> String? {
        project.ios.flatMap { destination.incompatibility(with: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Where should \(project.name) launch?").font(.system(size: 15, weight: .semibold))
                Picker("Destination Type", selection: $kind) {
                    Text("Simulators").tag(LaunchDestination.Kind.simulator)
                    Text("My Devices").tag(LaunchDestination.Kind.device)
                }.pickerStyle(.segmented).labelsHidden()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search for an iPhone or iPad…", text: $query).textFieldStyle(.plain)
                        .accessibilityLabel("Search Destinations")
                }
                .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 28)
                .background(.fill.tertiary, in: Capsule())
            }.padding(14)
            Divider()
            if matches.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if model.isLoadingDestinations {
                        ProgressView("Looking for destinations…").controlSize(.small)
                    } else {
                        Text(query.isEmpty ? (kind == .device ? "No Devices Found" : "No Simulators Found") : "No Results")
                            .font(.system(size: 13, weight: .medium))
                        Text(query.isEmpty ? (kind == .device ? "Connect and unlock your iPhone or iPad. Accept pairing with this Mac if asked." : "Install an iOS runtime in Xcode’s settings, then refresh the list.") : "Try another name or iOS version.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { destinationRow($0) }
                    }.padding(8)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if kind == .device {
                    Text("The device must be unlocked and paired, with Developer Mode on. Signing uses the Apple team set in the project.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let remembered = model.destination(for: project), !model.isLoadingDestinations,
                   !model.destinations.contains(where: { $0.id == remembered.id }) {
                    Text("Last destination: \(remembered.name), currently not found.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                ForEach(model.destinationIssues, id: \.self) { issue in
                    Text(issue).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3).help(issue)
                }
                HStack(spacing: 10) {
                    Button("Refresh") { Task { await model.refreshDestinations() } }
                        .disabled(model.isLoadingDestinations || model.busyID != nil)
                    if model.isLoadingDestinations { ProgressView().controlSize(.mini) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(request.launch ? "Launch" : "Choose") { confirm() }
                        .buttonStyle(.tinted).keyboardShortcut(.defaultAction)
                        .disabled(selected == nil || selected.map { reason($0) != nil } == true || model.busyID != nil || model.isLoadingDestinations)
                }
            }.padding(14)
        }
        .frame(width: 400, height: 460)
        .onAppear {
            if let saved = model.destination(for: project) { kind = saved.kind; selectedID = saved.id }
        }
    }

    private func destinationRow(_ destination: LaunchDestination) -> some View {
        let unavailable = reason(destination)
        let isSelected = selectedID == destination.id
        return Button { selectedID = destination.id } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0).frame(width: 14)
                Image(systemName: destination.symbol).font(.system(size: 16)).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.name).font(.system(size: 13)).lineLimit(1)
                    if let unavailable {
                        Text(unavailable).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text((destination.family == 2 ? "iPadOS " : "iOS ") + destination.osVersion)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).frame(minHeight: 34)
            .background(isSelected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(unavailable != nil || model.busyID != nil)
            .opacity(unavailable == nil ? 1 : 0.6)
            .accessibilityLabel(destination.label).accessibilityValue(unavailable ?? destination.status)
            .help(unavailable ?? "\(destination.label) · \(destination.status)")
    }

    private func confirm() {
        guard let destination = selected, reason(destination) == nil else { return }
        model.chooseDestination(destination, for: project)
        dismiss()
        if request.launch { model.launch(project, force: request.force) }
    }
}
