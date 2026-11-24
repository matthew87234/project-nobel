#if DEBUG
import Foundation

public struct TestRunner {
    private static let totalSuites = 17
    private static var assertionCount = 0
    private static var failureCount = 0
    private static var lastSuiteFailureCount = 0
    
    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String = "Assertion failed",
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        assertionCount += 1
        if !condition() {
            failureCount += 1
            print("  [FAIL] \(file):\(line): \(message())")
        }
    }
    
    private static func reportSuite(_ index: Int, _ name: String) {
        if failureCount == lastSuiteFailureCount {
            print("  [PASS] [\(index)/\(totalSuites)] \(name) passed")
        } else {
            let newFailures = failureCount - lastSuiteFailureCount
            print("  [FAIL] [\(index)/\(totalSuites)] \(name) FAILED (\(newFailures) failure(s))")
            lastSuiteFailureCount = failureCount
        }
    }
    
    @MainActor
    public static func runTests() {
        assertionCount = 0
        failureCount = 0
        lastSuiteFailureCount = 0
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[TEST] Executing Project Nobel Built-in Test Suite...")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        let helper = AIHelper.shared
        
        // 1. isStepHeader tests
        expect(helper.isStepHeader("Step 1: Calculate force"))
        expect(helper.isStepHeader("Step 2. Calculate energy"))
        expect(helper.isStepHeader("**Step 3:** Calculate charge"))
        expect(helper.isStepHeader("### Step 4: Solve"))
        expect(helper.isStepHeader("1. Convert units"))
        expect(helper.isStepHeader("2) Substitute values"))
        expect(helper.isStepHeader("- Use Coulomb's law"))
        expect(helper.isStepHeader("* Compute the integral"))
        expect(!helper.isStepHeader("Here is the step-by-step solution:"))
        expect(!helper.isStepHeader("To solve this, we can follow these steps:"))
        expect(!helper.isStepHeader("$$E = mc^2$$"))
        expect(!helper.isStepHeader("This is not a step."))
        expect(!helper.isStepHeader("2026-07-14"))
        reportSuite(1, "testIsStepHeader")
        
        // 2. cleanStepText tests
        expect(helper.cleanStepText("Step 1: Calculate force") == "Calculate force")
        expect(helper.cleanStepText("**Step 2:** Find potential") == "Find potential")
        expect(helper.cleanStepText("### Step 3. Solve integration") == "Solve integration")
        expect(helper.cleanStepText("1. Convert to SI units") == "Convert to SI units")
        expect(helper.cleanStepText("2) Substitute $x=5$") == "Substitute $x=5$")
        expect(helper.cleanStepText("- Compute the final value") == "Compute the final value")
        expect(helper.cleanStepText("**Heaviest boson:** **Higgs**") == "Heaviest boson: Higgs")
        expect(helper.cleanStepText("- **Reaction 1:** **Forbidden**") == "Reaction 1: Forbidden")
        reportSuite(2, "testCleanStepText")
        
        // 3. parseStepsFromLLMResponse tests
        let response1 = """
        Here is the step-by-step solution to the physics problem:
        
        Step 1: Identify the given quantities.
        We have $m = 2\\text{ kg}$ and $a = 5\\text{ m/s}^2$.
        
        Step 2: Apply Newton's second law.
        $$F = ma$$
        
        Step 3: Calculate the force.
        $$F = 2 \\times 5 = 10\\text{ N}$$
        
        I hope this helps! Let me know if you need more details.
        """
        let steps1 = helper.parseStepsFromLLMResponse(response1)
        expect(steps1.count == 3)
        expect(steps1[0] == "Identify the given quantities.\nWe have $m = 2\\text{ kg}$ and $a = 5\\text{ m/s}^2$.")
        expect(steps1[1] == "Apply Newton's second law.\n$$F = ma$$")
        expect(steps1[2] == "Calculate the force.\n$$F = 2 \\times 5 = 10\\text{ N}$$")
        
        let response2 = """
        - First, identify $v_0 = 10\\text{ m/s}$.
        - Second, use $v = v_0 + at$.
        - Third, solve for $v = 15\\text{ m/s}$.
        """
        let steps2 = helper.parseStepsFromLLMResponse(response2)
        expect(steps2.count == 3)
        expect(steps2[0] == "First, identify $v_0 = 10\\text{ m/s}$.")
        expect(steps2[1] == "Second, use $v = v_0 + at$.")
        expect(steps2[2] == "Third, solve for $v = 15\\text{ m/s}$.")
        
        let response3 = """
        1. Write the Schrodinger equation.
        2. Set up boundary conditions.
        """
        let steps3 = helper.parseStepsFromLLMResponse(response3)
        expect(steps3.count == 2)
        expect(steps3[0] == "Write the Schrodinger equation.")
        expect(steps3[1] == "Set up boundary conditions.")
        
        let response4 = """
        First, we calculate the gradient. The potential function is given.
        
        Then, we find the electric field as the negative gradient of potential.
        """
        let steps4 = helper.parseStepsFromLLMResponse(response4)
        expect(steps4.count == 2)
        expect(steps4[0] == "[Conceptual Setup]\n\nFirst, we calculate the gradient. The potential function is given.")
        expect(steps4[1] == "[Governing Formulation]\n\nThen, we find the electric field as the negative gradient of potential.")
        
        let response5 = """
        [STEP]
        Tier: Conceptual Setup
        Subpart: (i)
        Content: State Euler reciprocity relation:
        $$
        \\frac{\\partial M}{\\partial y} = \\frac{\\partial N}{\\partial x}
        $$
        [/STEP]
        [STEP]
        Tier: Governing Formulation
        Subpart: (i)
        Content: Apply to differential $dG = \\alpha dx + \\beta \\frac{x}{y} dy$.
        [/STEP]
        [STEP]
        Tier: Algebraic Derivation
        Subpart: (i)
        Content: Conclude exactness test.
        [/STEP]
        """
        let steps5 = helper.parseStepsFromLLMResponse(response5)
        expect(steps5.count == 3)
        expect(steps5[0].contains("[Conceptual Setup]"))
        expect(steps5[0].contains("(i)"))
        expect(steps5[1].contains("[Governing Formulation]"))
        expect(steps5[2].contains("[Algebraic Derivation]"))
        reportSuite(3, "testParseStepsFromLLMResponse")
        
        // 4. splitSolutionIntoSubparts
        let solution = """
        (i) Noting that N = n_up + n_down, we find E = mu H (N - 2n_up).
        (ii) There are N C n_up configurations, giving entropy S(n_up) via Stirling's approximation.
        (iii) Microcanonical vs Canonical ensemble comparison.
        (iv) Temperature reciprocal 1/T and negative temperature limit.
        """
        let subparts = helper.splitSolutionIntoSubparts(solution)
        expect(subparts.count == 4)
        expect(subparts[0].subpart == "(i)")
        expect(subparts[0].content.contains("E = mu H"))
        expect(subparts[1].subpart == "(ii)")
        expect(subparts[1].content.contains("Stirling's approximation"))
        expect(subparts[2].subpart == "(iii)")
        expect(subparts[3].subpart == "(iv)")
        reportSuite(4, "testSplitSolutionIntoSubparts")
        
        // 5. Glitch and repetition detection & Hybrid offline policy
        expect(!helper.hasRepetitiveGlitch("Short unique math text."))
        expect(!helper.hasRepetitiveGlitch("Value = 1000000 eV"))
        expect(helper.hasRepetitiveGlitch("Energy = aaaaaa"))
        expect(helper.hasRepetitiveGlitch(String(repeating: "Identical repeating line of text.\n", count: 20)))
        let savedOfflinePolicy = UserDefaults.standard.object(forKey: "hybrid_offline_policy")
        UserDefaults.standard.removeObject(forKey: "hybrid_offline_policy")
        expect(!helper.shouldFallbackToLocalWhenRemoteOffline)
        UserDefaults.standard.set("wait", forKey: "hybrid_offline_policy")
        expect(!helper.shouldFallbackToLocalWhenRemoteOffline)
        UserDefaults.standard.set("fallback", forKey: "hybrid_offline_policy")
        expect(helper.shouldFallbackToLocalWhenRemoteOffline)
        if let savedOfflinePolicy {
            UserDefaults.standard.set(savedOfflinePolicy, forKey: "hybrid_offline_policy")
        } else {
            UserDefaults.standard.removeObject(forKey: "hybrid_offline_policy")
        }
        reportSuite(5, "testRepetitiveGlitchDetection")
        
        // 6. Tabular to Array Conversion tests
        let tabularInput = """
        \\begin{tabular}{|c|c|}
        \\hline
        Name & Mass \\\\
        \\hline
        anti-neutron & 939 MeV \\\\
        \\hline
        \\end{tabular}
        """
        let convertedTable = convertTabularToArray(tabularInput)
        expect(convertedTable.contains("\\begin{array}{|c|c|}"))
        expect(convertedTable.contains("\\end{array}"))
        expect(convertedTable.contains("$$"))
        expect(convertedTable.contains("\\text{Name}"))
        expect(convertedTable.contains("\\text{Mass}"))
        reportSuite(6, "testTabularConversion")
        
        // 7. sanitizeLaTeX markdown asterisks and url tests
        let rawWithStars = "**Heaviest boson:** **Higgs** online \\url{http://pdg.lbl.gov}"
        let sanitized = sanitizeLaTeX(rawWithStars)
        expect(!sanitized.contains("**"))
        expect(!sanitized.contains("\\url"))
        expect(sanitized.contains("Heaviest boson: Higgs"))
        expect(sanitized.contains("http://pdg.lbl.gov"))
        reportSuite(7, "testMarkdownBoldStripping")
        
        // 8. FlashcardScheduler prioritization & SM-2 Hard interval progression tests
        let untouchedCard = Flashcard(id: 1, moduleId: 1, front: "U1", back: "B1", nextReviewDate: "2026-10-01", interval: 0, easeFactor: 2.5, repetitions: 0, createdDate: "2026-10-01", isFlagged: false)
        let overdueCard = Flashcard(id: 2, moduleId: 2, front: "O1", back: "B2", nextReviewDate: "2026-10-17", interval: 1, easeFactor: 1.5, repetitions: 0, createdDate: "2026-10-01", isFlagged: false)
        let dueTodayCards = (3...20).map { idx in
            Flashcard(id: idx, moduleId: (idx % 2) + 1, front: "D\(idx)", back: "B\(idx)", nextReviewDate: "2026-11-01", interval: 1, easeFactor: 1.8, repetitions: 0, createdDate: "2026-10-15", isFlagged: false)
        }
        let sessionDeck = FlashcardScheduler.buildSessionDeck(
            candidates: [untouchedCard, overdueCard] + dueTodayCards,
            targetCount: 5,
            today: "2026-11-01",
            studyAhead: false
        )
        expect(sessionDeck.count == 5, "Session deck should match targetCount")
        expect(sessionDeck.contains(where: { $0.id == 1 }), "Untouched card must be prioritized into session deck")
        expect(sessionDeck.contains(where: { $0.id == 2 }), "Oldest overdue card must be prioritized into session deck")
        expect(FlashcardScheduler.calculateNextInterval(card: untouchedCard, quality: 3) == 3.8, "First Good rating on untouched card (ease 2.5) must schedule 3.8d out")
        expect(FlashcardScheduler.calculateNextInterval(card: overdueCard, quality: 3) == 3.6, "Good rating on interval=1, ease=1.5 card must advance to 3.6d")
        expect(FlashcardScheduler.calculateNextInterval(card: overdueCard, quality: 2) == 3.0, "Hard rating on interval=1 card must advance to 3.0d")
        expect(FlashcardScheduler.calculateNextRepetitions(card: overdueCard, quality: 2) == 1, "Hard rating must advance repetitions to at least 1")
        expect(FlashcardScheduler.calculateNextEaseFactor(currentEase: 2.5, quality: 3) == 2.5, "Good rating must not penalize ease factor")
        reportSuite(8, "testFlashcardScheduler")
        
        // 9. Question Subpart Extraction & "i.e." avoidance
        let unifiedProblemWithIE = """
        For $\\hat{H}(t) = \\hat{H}$, i.e., a time-independent Hamiltonian, we found that the solution to this equation was
        $$U(t, t_0) = \\exp \\left( -\\frac{i}{\\hbar} \\hat{H}(t - t_0) \\right) \\,.$$
        Show that this means we can write the spectral decomposition.
        """
        expect(!helper.questionHasSubparts(unifiedProblemWithIE), "Question with 'i.e.' must not be identified as having subparts")
        
        let problemWithImplicitPreambleA = """
        The 0-th energy eigenstate of the simple harmonic oscillator can be written as
        $$|0\\rangle = \\alpha_0 \\int dx \\psi_0(x) |x\\rangle$$
        Work out what \\alpha_0 is.
        (b) The second energy eigenstate can similarly be written as...
        (c) Show that \\langle 0|2\\rangle = 0.
        (d) What does this imply about the states?
        """
        let extractedSubs = helper.extractQuestionSubparts(problemWithImplicitPreambleA)
        expect(extractedSubs.count == 4, "Implicit preamble before (b) must be inferred as (a), producing 4 subparts")
        expect(extractedSubs[0].subpart == "(a)")
        expect(extractedSubs[1].subpart == "(b)")
        expect(extractedSubs[2].subpart == "(c)")
        expect(extractedSubs[3].subpart == "(d)")
        expect(helper.questionHasSubparts(problemWithImplicitPreambleA))
        reportSuite(9, "testQuestionSubpartExtraction")
        
        // 10. OCR Answer Deduplication
        let repeatedAnswer = AIHelper.ExtractedAnswer(label: "Problem Continuation", content: "$$\\int dx \\, e^{-c^2 x^2} = \\sqrt{\\pi / c^2}$$")
        let distinctAnswer = AIHelper.ExtractedAnswer(label: "Part (b)", content: "$$\\langle 0 | \\hat{p} | 0 \\rangle = 0$$")
        let rawAnswers = [repeatedAnswer, repeatedAnswer, repeatedAnswer, repeatedAnswer, distinctAnswer]
        let deduplicated = helper.deduplicateExtractedAnswers(rawAnswers)
        expect(deduplicated.count == 2, "4 identical repeated OCR blocks must be deduplicated into 1")
        expect(deduplicated[0].label == "Problem Continuation")
        expect(deduplicated[1].label == "Part (b)")
        reportSuite(10, "testDeduplicateAnswers")
        
        // 11. Unclosed [STEP] parsing and untagged paragraph consolidation
        let unclosedStepResponse = """
        [STEP]
        Tier: Conceptual Setup
        Subpart: (a)
        Content: State the ground state wavefunction:
        $$
        \\psi_0(x) = \\exp(-c^2 x^2)
        $$
        [STEP]
        Tier: Governing Formulation
        Subpart: (a)
        Content: Integrate over the full real line.
        """
        let parsedUnclosed = helper.parseStepsFromLLMResponse(unclosedStepResponse, hasSubparts: true)
        expect(parsedUnclosed.count == 2, "Unclosed [STEP] response must produce 2 valid steps")
        expect(parsedUnclosed[0].contains("[Conceptual Setup]"), "Step 1 must contain [Conceptual Setup]")
        expect(!parsedUnclosed[0].contains("[STEP]"), "Raw [STEP] tags must never leak into step content")
        expect(parsedUnclosed[1].contains("[Governing Formulation]"), "Step 2 must contain [Governing Formulation]")
        
        let untaggedFragmentedResponse = """
        The inverse operator relation can be shown by direct substitution.
        
        $$
        \\frac{1}{\\hat{A}} - \\frac{1}{\\hat{B}} = \\frac{1}{\\hat{A}} (\\hat{B} - \\hat{A}) \\frac{1}{\\hat{B}}
        $$
        
        We multiply through by A and B to verify the identity.
        
        $$
        = \\frac{1}{\\hat{A}} \\hat{B} \\frac{1}{\\hat{B}} - \\frac{1}{\\hat{A}} \\hat{A} \\frac{1}{\\hat{B}}
        $$
        """
        let consolidatedSteps = helper.parseStepsFromLLMResponse(untaggedFragmentedResponse, hasSubparts: false)
        expect(consolidatedSteps.count <= 3, "Untagged isolated equations must be consolidated into structured steps")
        expect(consolidatedSteps[0].contains("[Conceptual Setup]"), "Untagged step 1 must be auto-assigned a diagnostic tier")
        reportSuite(11, "testUnclosedStepParsingAndParagraphConsolidation")
        
        // 12. Thinking Block Stripping & Non-Thinking Verification (preserve user UserDefaults)
        let prevTextThinking = UserDefaults.standard.object(forKey: "ai_text_thinking_enabled")
        let prevVisionThinking = UserDefaults.standard.object(forKey: "ai_vision_thinking_enabled")
        defer {
            if let prevTextThinking {
                UserDefaults.standard.set(prevTextThinking, forKey: "ai_text_thinking_enabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "ai_text_thinking_enabled")
            }
            if let prevVisionThinking {
                UserDefaults.standard.set(prevVisionThinking, forKey: "ai_vision_thinking_enabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "ai_vision_thinking_enabled")
            }
        }
        
        let thinkingResponse = """
        <think>
        The user wants to derive the energy eigenvalues.
        First, apply the Hamiltonian to the eigenstate.
        </think>
        [STEP]
        Tier: Conceptual Setup
        Subpart: (a)
        Content: Apply the Hamiltonian operator $\\hat{H} |n\\rangle = E_n |n\\rangle$.
        [STEP]
        Tier: Verification & Result
        Subpart: (a)
        Content: The resulting energy is $E_n = \\hbar \\omega (n + 1/2)$.
        """
        let parsedThinking = helper.parseStepsFromLLMResponse(thinkingResponse, hasSubparts: true)
        expect(parsedThinking.count == 2, "Thinking trace must be stripped, leaving 2 valid steps")
        expect(!parsedThinking[0].contains("<think>") && !parsedThinking[0].contains("</think>"), "Step must not contain think tags")
        expect(!parsedThinking[0].contains("The user wants to derive"), "Thinking monologue must be omitted")
        expect(parsedThinking[0].contains("[Conceptual Setup]"), "Step 1 must have Conceptual Setup")
        
        let genReq = GenerateRequest(model: "qwen3:8b", prompt: "test", stream: false, think: false)
        let encData = try? JSONEncoder().encode(genReq)
        let encStr = encData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(encStr.contains("\"think\":false"), "GenerateRequest must encode think:false in JSON payload")
        UserDefaults.standard.set(true, forKey: "ai_text_thinking_enabled")
        UserDefaults.standard.set(false, forKey: "ai_vision_thinking_enabled")
        expect(UserDefaults.standard.bool(forKey: "ai_text_thinking_enabled") == true, "Text thinking should be enabled")
        expect(UserDefaults.standard.bool(forKey: "ai_vision_thinking_enabled") == false, "Vision thinking should be disabled")
        reportSuite(12, "testThinkingBlockStripping")
        
        // 13. LaTeX Cleaning & Reasoning Suppression
        let rawLatexWithFences = """
        ```latex
        \\hat{J}_\\pm |j, m_j\\rangle = \\hbar \\sqrt{j(j+1) - m_j(m_j \\pm 1)} |j, m_j \\pm 1\\rangle
        ```
        """
        expect(helper.cleanLaTeXOutput(rawLatexWithFences) == "\\hat{J}_\\pm |j, m_j\\rangle = \\hbar \\sqrt{j(j+1) - m_j(m_j \\pm 1)} |j, m_j \\pm 1\\rangle")
        
        let rawWithPreamble = """
        The equation is:
        $$\\int_{a}^{b} x^2 \\, dx$$
        """
        expect(helper.cleanLaTeXOutput(rawWithPreamble) == "\\int_{a}^{b} x^2 \\, dx")
        
        let pureThinkingOutput = "<think>\nLet's see what the image shows...\n</think>"
        expect(helper.cleanLaTeXOutput(pureThinkingOutput) == nil, "Pure thinking output must resolve to nil")
        
        let cutOffThinkingOutput = "<think>\nLet's analyze the differential operator without closing tag"
        expect(helper.cleanLaTeXOutput(cutOffThinkingOutput) == nil, "Cut-off thinking block must resolve to nil")
        reportSuite(13, "testLaTeXCleaningAndReasoningSuppression")
        
        // 14. LaTeX align conversion, double-backslash fix, and placeholder template escaping
        let alignRaw = #"\begin{align*} x &= 1 \end{align*}"#
        let alignSanitized = sanitizeLaTeX(alignRaw)
        expect(alignSanitized.contains(#"\begin{aligned}"#), "align* must convert to \\begin{aligned}")
        expect(alignSanitized.contains(#"\end{aligned}"#), "end{align*} must convert to \\end{aligned}")
        
        let dblCmdSanitized = sanitizeLaTeX(#"\\frac{1}{2} \\ \alpha"#)
        expect(dblCmdSanitized.contains(#"\frac{1}{2}"#), "Double backslash command must collapse to single backslash \\frac")
        expect(!dblCmdSanitized.contains("$1"), "Double backslash fix must not leak $1 template literal")
        expect(dblCmdSanitized.contains(#"\\ \alpha"#), "LaTeX line break \\\\ must be preserved")
        
        var draftWithPlaceholder = "Derive: [AI: Generating LaTeX...] then simplify."
        let trickLatex = #"$\frac{1}{2} + $0$"#
        AILatexPlaceholder.replaceOrAppend(in: &draftWithPlaceholder, with: trickLatex)
        expect(draftWithPlaceholder == #"Derive: $\frac{1}{2} + $0$ then simplify."#, "Placeholder replacement must preserve backslashes and $0 verbatim")
        reportSuite(14, "testLaTeXAlignBackslashAndPlaceholderEscaping")
        
        // 15. Pre-Lecture Primer UTF-16 Unicode parsing (no final section truncation & inline brackets preserved)
        let unicodePrimer = """
        [What Happened in the Last Lecture]
        We integrated ∫ ψ*(x) ℏ ∂_x ψ(x) dx over ℝ and summed ∑_{n=0}^∞ c_n → 1, with résumé note élan.

        [How it Links into This Lecture]
        Next we compute ⟨ψ|Ĥ|ψ⟩ using ∑_n E_n |c_n|^2 in ℝ³.

        [What You Will Learn Today]
        Spectral decomposition for Hermitian operators ∑ ∫ ℏ ψ ℝ.

        [Three Open Questions for the Lecture]
        - 1. Why is ℏ ≠ 0 critical for ⟨[x̂, p̂]⟩?
        - 2. Does ∑_n |c_n|^2 = 1 hold for scattering states in ℝ?
        """
        let primerSections = PreLectureView.parsePrimerSections(unicodePrimer)
        expect(primerSections.count == 4, "All 4 Unicode primer sections must be parsed (got \(primerSections.count))")
        expect(primerSections.last?.content.contains("scattering states in ℝ?") == true, "Final primer section must not be truncated by UTF-16 vs Character count mismatch")
        reportSuite(15, "testPreLectureUnicodeSectionParsing")
        
        // 16. Exam date parsing & weekly time distribution bucketing
        expect(ModuleManagerView.parseExamDate("2026-05-18 09:30") != nil, "Full datetime exam date must parse")
        expect(ModuleManagerView.parseExamDate("2026-05-18") != nil, "Date-only exam date must parse cleanly")
        expect(ModuleManagerView.parseExamDate("") == nil, "Empty exam date must return nil")
        
        let buckets = DatabaseManager.bucketTimeDurations([2, 7, 12, 18, 25, 40, 55, 75])
        expect(buckets.count == 8, "Should produce 8 time distribution bins")
        expect(buckets.allSatisfy { $0.count == 1 }, "Each sample duration must land in its exact bin (got \(buckets))")
        let emptyBuckets = DatabaseManager.bucketTimeDurations([])
        expect(emptyBuckets.allSatisfy { $0.count == 0 }, "Empty durations must produce all-zero bins")
        reportSuite(16, "testExamDateAndTimeDistributionBucketing")
        
        // 17. Shared LaTeX delimiter wrapping & POSIX cached DateFormatters
        expect(LaTeXDelimiterHelper.wrap("E = mc^2") == "$E = mc^2$", "Single-line math must wrap in inline $...$")
        expect(LaTeXDelimiterHelper.wrap("E = mc^2", preferBlock: true) == "$$\nE = mc^2\n$$", "preferBlock must wrap in $$...$$ block")
        expect(LaTeXDelimiterHelper.wrap("$$x+y$$") == "$$x+y$$", "Already-delimited LaTeX must be preserved verbatim")
        
        let sampleDateStr = "2026-05-18"
        let parsedDateOnly = DatabaseManager.dateFormatter.date(from: sampleDateStr)
        expect(parsedDateOnly != nil && DatabaseManager.dateFormatter.string(from: parsedDateOnly!) == sampleDateStr, "POSIX dateFormatter must round-trip yyyy-MM-dd")
        let sampleDateTimeStr = "2026-05-18 09:30"
        let parsedDateTime = DatabaseManager.dateTimeFormatter.date(from: sampleDateTimeStr)
        expect(parsedDateTime != nil && DatabaseManager.dateTimeFormatter.string(from: parsedDateTime!) == sampleDateTimeStr, "POSIX dateTimeFormatter must round-trip yyyy-MM-dd HH:mm")
        reportSuite(17, "testLaTeXDelimiterWrappingAndDateFormatters")
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        if failureCount > 0 {
            print("[FAIL] \(failureCount) assertion(s) failed out of \(assertionCount) checks across \(totalSuites) test suites!")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            exit(1)
        } else {
            print("[PASS] ALL \(totalSuites) TEST SUITES PASSED (\(assertionCount) assertions verified)!")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        }
    }
}
#endif
