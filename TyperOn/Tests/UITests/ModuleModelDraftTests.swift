// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Test(arguments: ["translation", "content-generation", "custom-test"])
func moduleModelSelectionRoundTripsWithoutChangingOtherSettings(moduleID: String) throws {
    let globalModel = "global/original"
    let other = ModuleAIConfig(useGlobal: false, customModel: "other/unchanged")
    var configs = [moduleID: ModuleAIConfig(useGlobal: false, usesModuleAPIKey: true), "other": other]
    var draft = ModuleModelDraft(customModel: configs[moduleID]?.customModel)
    #expect(draft.effectiveModel(globalModel: globalModel) == globalModel)
    #expect(draft.effectiveModel(globalModel: "global/changed") == "global/changed")

    for selection in ["openai/gpt-4o", "  private/manual-model\n", ""] {
        let savedBeforeSelection = try JSONEncoder().encode(configs[moduleID])
        draft.select(selection)
        #expect(try JSONDecoder().decode(ModuleAIConfig.self, from: savedBeforeSelection).customModel == configs[moduleID]?.customModel)
        configs[moduleID]?.customModel = draft.customModel
        let reopened = try JSONDecoder().decode([String: ModuleAIConfig].self, from: JSONEncoder().encode(configs))
        draft = ModuleModelDraft(customModel: reopened[moduleID]?.customModel)
        #expect(draft.customModel == (selection.isEmpty ? nil : selection.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(reopened[moduleID]?.usesModuleAPIKey == true)
        #expect(reopened[moduleID]?.useGlobal == false)
        #expect(reopened["other"]?.customModel == "other/unchanged")
        #expect(globalModel == "global/original")
    }
    #expect(draft.customModel == nil)
    #expect(draft.effectiveModel(globalModel: globalModel) == globalModel)
}

@Test
func moduleCatalogCredentialPriorityDoesNotReadUnneededKeys() {
    func unexpectedRead() -> String? {
        Issue.record("Lower priority credential should not be read")
        return nil
    }
    #expect(ModuleModelDraft.catalogAPIKey(enteredKey: "  draft-key\n", storedModuleKey: unexpectedRead(), globalKey: unexpectedRead()) == "draft-key")
    #expect(ModuleModelDraft.catalogAPIKey(enteredKey: " \n", storedModuleKey: "stored-key", globalKey: unexpectedRead()) == "stored-key")
    #expect(ModuleModelDraft.catalogAPIKey(enteredKey: "", storedModuleKey: nil, globalKey: "global-key") == "global-key")
    #expect(ModuleModelDraft.catalogAPIKey(enteredKey: "", storedModuleKey: " \n", globalKey: nil) == "")
}
