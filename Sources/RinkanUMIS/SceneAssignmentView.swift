import SwiftUI

struct SceneAssignmentView: View {
    @EnvironmentObject private var model: AppModel

    private var availableDays: [Int] {
        SceneDaySelectionPolicy.availableDays(in: model.scenes)
    }

    private var visibleScenes: [AppScene] {
        SceneDaySelectionPolicy.visibleScenes(in: model.scenes, day: model.selectedSceneDay)
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: {
                SceneDaySelectionPolicy.visibleSelection(
                    model.selectedSceneID,
                    scenes: model.scenes,
                    day: model.selectedSceneDay
                )
            },
            set: { id in
                guard model.canInteractWithScenePanel else { return }
                model.selectedSceneID = SceneDaySelectionPolicy.visibleSelection(
                    id,
                    scenes: model.scenes,
                    day: model.selectedSceneDay
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("シーン")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(availableDays.filter { $0 > 0 }, id: \.self) { day in
                        Button("\(day)日目へ追加") { addScene(day: day) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("シーンを追加")
                .help("撮影日を選んで新しいシーンを追加")
            }
            .padding(12)

            SceneDayFilterButtons(days: availableDays, selectedDay: model.selectedSceneDay) {
                model.selectSceneDay($0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Text("\(SceneDaySelectionPolicy.label(for: model.selectedSceneDay))・\(visibleScenes.count)シーン")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            List(selection: selection) {
                ForEach(visibleScenes) { scene in
                    sceneRow(scene)
                }
            }
            .overlay {
                if visibleScenes.isEmpty {
                    VStack(spacing: 8) {
                        Text("この日のシーンはありません")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if model.selectedSceneDay > 0 {
                            Button("シーンを追加") { addScene(day: model.selectedSceneDay) }
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
            assignmentActions
        }
        .disabled(!model.canInteractWithScenePanel)
    }

    private func sceneRow(_ scene: AppScene) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(scene.code)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(
                        "シーン名",
                        text: Binding(
                            get: {
                                model.scenes.first(where: { $0.id == scene.id })?.name ?? scene.name
                            },
                            set: {
                                guard model.canInteractWithScenePanel,
                                      model.scenes.contains(where: {
                                          $0.id == scene.id && $0.day == model.selectedSceneDay
                                      }) else { return }
                                model.updateSceneName(id: scene.id, name: $0)
                            }
                        )
                    )
                    .textFieldStyle(.plain)
                    .accessibilityLabel("\(scene.code)のシーン名")
                }
                Text("\(model.assignmentCount(for: scene.id))項目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .tag(scene.id)
        .contextMenu {
            Button("上へ移動") { moveScene(scene, offset: -1) }
                .disabled(visibleScenes.first?.id == scene.id)
            Button("下へ移動") { moveScene(scene, offset: 1) }
                .disabled(visibleScenes.last?.id == scene.id)
            Divider()
            if scene.day != 0 {
                Button("削除", role: .destructive) {
                    guard let currentScene = currentVisibleScene(id: scene.id) else { return }
                    model.removeScene(currentScene)
                }
                .disabled(model.assignmentCount(for: scene.id) > 0)
            }
        }
    }

    private var assignmentActions: some View {
        VStack(spacing: 8) {
            Button("選択素材を割り当て") {
                guard model.canInteractWithScenePanel, model.selectedSceneIsVisible else { return }
                model.assignSelectionToCurrentScene()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(model.visibleSelectedIngestAssetIDs.isEmpty || !model.selectedSceneIsVisible)
            .help("選択中の素材を、表示中の日の選択したシーンへ割り当て（⌘Return）")
            if model.visibleSelectedIngestAssetIDs.isEmpty {
                Text("中央の素材を選択してから、割り当て先のシーンを選んでください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !model.selectedSceneIsVisible {
                Text("この日の割り当て先シーンを選択してください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("選択素材の割り当てを解除") {
                guard model.canInteractWithScenePanel else { return }
                model.removeAssignmentsForSelection()
            }
            .frame(maxWidth: .infinity)
            .disabled(model.visibleSelectedIngestAssetIDs.isEmpty)
            Divider()
            Button("選択素材を今回の取り込みから除外") {
                guard model.canInteractWithScenePanel else { return }
                model.excludeSelectionFromIngest()
            }
            .frame(maxWidth: .infinity)
            .disabled(model.visibleSelectedIngestAssetIDs.isEmpty)
            Button("選択素材を取り込み対象に戻す") {
                guard model.canInteractWithScenePanel else { return }
                model.includeSelectionInIngest()
            }
            .frame(maxWidth: .infinity)
            .disabled(model.visibleSelectedIngestAssetIDs.isDisjoint(with: model.explicitlyExcludedAssetIDs))
            if !model.explicitlyExcludedAssetIDs.isEmpty {
                Button("除外をすべて戻す（\(model.explicitlyExcludedAssetIDs.count)件）") {
                    guard model.canInteractWithScenePanel else { return }
                    model.restoreAllExcludedAssets()
                }
                .frame(maxWidth: .infinity)
            }
            if model.unreviewedEmptyDirectoryCount > 0 {
                Text("空フォルダ \(model.unreviewedEmptyDirectoryCount)件の判断が未確認です")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
    }

    private func addScene(day: Int) {
        guard model.canInteractWithScenePanel,
              day > 0,
              availableDays.contains(day) else { return }
        model.addScene(day: day)
    }

    private func moveScene(_ scene: AppScene, offset: Int) {
        guard let currentScene = currentVisibleScene(id: scene.id) else { return }
        model.moveScene(currentScene, offset: offset)
    }

    private func currentVisibleScene(id: UUID) -> AppScene? {
        guard model.canInteractWithScenePanel else { return nil }
        return model.scenes.first { $0.id == id && $0.day == model.selectedSceneDay }
    }
}

struct SceneDayFilterButtons: View {
    let days: [Int]
    let selectedDay: Int
    let selectDay: (Int) -> Void

    var body: some View {
        // Keep the ordinary five choices visible in two rows. Imported/shared projects can
        // contain additional day numbers; these remain reachable without growing the panel.
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                    ForEach(days, id: \.self) { day in
                        Toggle(isOn: Binding(
                            get: { selectedDay == day },
                            set: { _ in selectDay(day) }
                        )) {
                            Text(SceneDaySelectionPolicy.label(for: day))
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("\(SceneDaySelectionPolicy.label(for: day))のシーンだけを表示")
                        .accessibilityLabel("シーンの撮影日: \(SceneDaySelectionPolicy.label(for: day))")
                        .accessibilityValue(selectedDay == day ? "選択中" : "未選択")
                        .accessibilityIdentifier("scene-day-\(day)")
                        .id(day)
                    }
                }
            }
            .onAppear { proxy.scrollTo(selectedDay, anchor: .center) }
            .onChange(of: selectedDay) { day in proxy.scrollTo(day, anchor: .center) }
        }
        .frame(height: min(104, CGFloat((days.count + 2) / 3) * 26))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("シーンの撮影日を切り替え")
    }
}
