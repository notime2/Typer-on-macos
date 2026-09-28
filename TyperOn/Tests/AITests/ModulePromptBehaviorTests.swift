// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Testing
@testable import Typer_On

@Test
func testSummarizationDefaultLanguageRuleUsesTargetLanguage() {
    let module = SummarizationModule()
    let context = makeContext(targetLanguage: "German", outputLanguageMode: .defaultLanguage, sourceLanguageName: "English")

    let prompt = systemPrompt(from: module.buildPrompt(for: "Hello world", context: context))
    #expect(prompt.contains("The summary must be in German"))
}

@Test
func testGrammarSourceLanguageRuleUsesSourceLanguage() {
    let module = GrammarFixModule()
    let context = makeContext(targetLanguage: "German", outputLanguageMode: .sourceLanguage, sourceLanguageName: "Spanish")

    let prompt = systemPrompt(from: module.buildPrompt(for: "Hola mundo", context: context))
    #expect(prompt.contains("The corrected text must be in Spanish"))
}

@Test
func testTranslationDefaultModeKeepsFallbackToEnglishWhenInputMatchesPreferredLanguage() {
    let module = TranslationModule()
    let context = makeContext(targetLanguage: "Russian", outputLanguageMode: .defaultLanguage, sourceLanguageName: "Russian")

    let prompt = systemPrompt(from: module.buildPrompt(for: "Привет мир", context: context))
    #expect(prompt.contains("Translate the given text to English"))
}

@Test
func testTranslationDefaultModeDetectsSourceLanguageWhenContextOmitsIt() {
    let module = TranslationModule()
    let context = makeContext(targetLanguage: "Russian", outputLanguageMode: .defaultLanguage, sourceLanguageName: nil)
    let russianText = "Сегодня утром я выпил кофе и пошёл на работу, потому что настроение было хорошее."

    let prompt = systemPrompt(from: module.buildPrompt(for: russianText, context: context))
    #expect(prompt.contains("Translate the given text to English"))
}

@Test
func testTranslationDefaultModeUsesContextFallbackWhenEnglishInputMatchesEnglishDefault() {
    let module = TranslationModule()
    let context = makeContext(
        targetLanguage: "English",
        outputLanguageMode: .defaultLanguage,
        sourceLanguageName: "English",
        fallbackTargetLanguage: "Russian"
    )

    let prompt = systemPrompt(from: module.buildPrompt(for: "Hello world", context: context))
    #expect(prompt.contains("Translate the given text to Russian"))
}

@Test
func testTranslationDefaultModeKeepsEnglishWhenNoDistinctFallbackExists() {
    let module = TranslationModule()
    let context = makeContext(targetLanguage: "English", outputLanguageMode: .defaultLanguage, sourceLanguageName: "English")

    let prompt = systemPrompt(from: module.buildPrompt(for: "Hello world", context: context))
    #expect(prompt.contains("Translate the given text to English"))
}

@Test
func testTranslationDefaultModeIgnoresFallbackThatEqualsDefault() {
    let module = TranslationModule()
    let context = makeContext(
        targetLanguage: "Russian",
        outputLanguageMode: .defaultLanguage,
        sourceLanguageName: "russian",
        fallbackTargetLanguage: "Russian"
    )

    let prompt = systemPrompt(from: module.buildPrompt(for: "Привет мир", context: context))
    #expect(prompt.contains("Translate the given text to English"))
}

@Test
func testTranslationDefaultModeTreatsTraditionalChineseAsChinese() {
    let module = TranslationModule()
    let context = makeContext(targetLanguage: "Chinese", outputLanguageMode: .defaultLanguage, sourceLanguageName: nil)
    let traditionalChineseText = "這是一個用繁體中文寫的句子，用來檢查語言偵測。"

    let prompt = systemPrompt(from: module.buildPrompt(for: traditionalChineseText, context: context))
    #expect(prompt.contains("Translate the given text to English"))
}

@Test
func testTranslationSourceModeTargetsSourceLanguage() {
    let module = TranslationModule()
    let context = makeContext(targetLanguage: "Russian", outputLanguageMode: .sourceLanguage, sourceLanguageName: "Spanish")

    let prompt = systemPrompt(from: module.buildPrompt(for: "Any input", context: context))
    #expect(prompt.contains("Translate the given text to Spanish"))
}

@Test
func testExplainDefaultLanguageRuleUsesTargetLanguage() {
    let module = ExplainModule()
    let context = makeContext(targetLanguage: "German", outputLanguageMode: .defaultLanguage, sourceLanguageName: "English")

    let prompt = systemPrompt(from: module.buildPrompt(for: "Hello world", context: context))
    #expect(prompt.contains("The explanation must be in German"))
}

@Test
func testExplainSourceLanguageRuleUsesSourceLanguageWhenModeChanged() {
    let module = ExplainModule()
    let context = makeContext(targetLanguage: "German", outputLanguageMode: .sourceLanguage, sourceLanguageName: "Spanish")

    let prompt = systemPrompt(from: module.buildPrompt(for: "Hola mundo", context: context))
    #expect(prompt.contains("The explanation must be in Spanish"))
}

@Test
func testExplainPromptRequiresBulletOutputFormat() {
    let module = ExplainModule()
    let context = makeContext(targetLanguage: "English", outputLanguageMode: .defaultLanguage, sourceLanguageName: "English")

    let prompt = systemPrompt(from: module.buildPrompt(for: "Any input", context: context))
    #expect(prompt.contains("Use 3-6 bullet points"))
    #expect(prompt.contains("Start each bullet point with \"- \""))
}

@Test
func testFactCheckDefaultLanguageRuleUsesTargetLanguage() {
    let module = FactCheckModule()
    let context = makeContext(targetLanguage: "German", outputLanguageMode: .defaultLanguage, sourceLanguageName: "English")

    let prompt = systemPrompt(from: module.buildPrompt(for: "Hello world", context: context))
    #expect(prompt.contains("The fact check must be in German"))
}

@Test
func testFactCheckSourceLanguageRuleUsesSourceLanguageWhenModeChanged() {
    let module = FactCheckModule()
    let context = makeContext(targetLanguage: "German", outputLanguageMode: .sourceLanguage, sourceLanguageName: "Spanish")

    let prompt = systemPrompt(from: module.buildPrompt(for: "Hola mundo", context: context))
    #expect(prompt.contains("The fact check must be in Spanish"))
}

@Test
func testFactCheckPromptRequiresCautiousAssessment() {
    let module = FactCheckModule()
    let context = makeContext(targetLanguage: "English", outputLanguageMode: .defaultLanguage, sourceLanguageName: "English")

    let prompt = systemPrompt(from: module.buildPrompt(for: "Any input", context: context))
    #expect(prompt.contains("Supported\", \"Unclear\", \"Likely incorrect\", or \"Opinion\""))
    #expect(prompt.contains("Do not invent sources, quotes, studies, dates, or statistics"))
}

@Test
func testFactCheckUsesCustomSystemPromptOverride() {
    let context = makeContext(
        targetLanguage: "German",
        outputLanguageMode: .defaultLanguage,
        sourceLanguageName: "English",
        customSystemPrompt: "CUSTOM OVERRIDE"
    )

    let prompt = systemPrompt(from: FactCheckModule().buildPrompt(for: "Hello", context: context))
    #expect(prompt == "CUSTOM OVERRIDE")
}

@Test
func testBuiltInModuleUsesCustomSystemPromptOverride() {
    let module = RephrasingModule()
    let context = makeContext(
        targetLanguage: "German",
        outputLanguageMode: .defaultLanguage,
        sourceLanguageName: "English",
        customSystemPrompt: "CUSTOM OVERRIDE"
    )

    let prompt = systemPrompt(from: module.buildPrompt(for: "Hello", context: context))
    #expect(prompt == "CUSTOM OVERRIDE")
}

@Test
func testContentGenerationModuleExposesChatModeShortDescription() {
    let module = ContentGenerationModule()
    #expect(module.shortDescription == "Chat on any topic or with context")
}

@Test
func testBuiltInModulesExposeSFSymbolIconIDs() {
    #expect(TranslationModule().icon == "globe")
    #expect(GrammarFixModule().icon == "checkmark.circle.dotted")
    #expect(RephrasingModule().icon == "arrow.trianglehead.2.clockwise.rotate.90")
    #expect(ToneAdjustmentModule().icon == "eyeglasses")
    #expect(SummarizationModule().icon == "sum")
    #expect(ExplainModule().icon == "magnifyingglass")
    #expect(FactCheckModule().icon == "checkmark.shield")
    #expect(ContentGenerationModule().icon == "app.background.dotted")
}

@Test
func testCustomPromptModuleAppliesBasePromptAndOverrideLayer() {
    let module = CustomPromptModule(
        id: "custom-test",
        name: "Custom Test",
        icon: "star",
        shortDescription: "Custom helper",
        systemPrompt: "Base custom prompt"
    )

    let baseContext = makeContext(targetLanguage: "French", outputLanguageMode: .defaultLanguage, sourceLanguageName: "English")
    let basePrompt = systemPrompt(from: module.buildPrompt(for: "Input", context: baseContext))
    #expect(basePrompt.contains("Base custom prompt"))
    #expect(basePrompt.contains("must be in French"))

    let overrideContext = makeContext(
        targetLanguage: "French",
        outputLanguageMode: .defaultLanguage,
        sourceLanguageName: "English",
        customSystemPrompt: "Override custom prompt"
    )
    let overridePrompt = systemPrompt(from: module.buildPrompt(for: "Input", context: overrideContext))
    #expect(overridePrompt.contains("Override custom prompt"))
    #expect(!overridePrompt.contains("Base custom prompt"))
}

private func makeContext(
    targetLanguage: String,
    outputLanguageMode: ModuleOutputLanguageMode,
    sourceLanguageName: String?,
    customSystemPrompt: String? = nil,
    fallbackTargetLanguage: String? = nil
) -> ModuleContext {
    var context = ModuleContext.default
    context.targetLanguage = targetLanguage
    context.outputLanguageMode = outputLanguageMode
    context.sourceLanguageName = sourceLanguageName
    context.customSystemPrompt = customSystemPrompt
    context.fallbackTargetLanguage = fallbackTargetLanguage
    return context
}

private func systemPrompt(from messages: [ChatMessage]) -> String {
    messages.first(where: { $0.role == "system" })?.content ?? ""
}
