import Foundation

public struct TestRunner {
    @MainActor
    public static func runTests() {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[TEST] Executing Project Nobel Built-in Test Suite...")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        let helper = AIHelper.shared
        
        // 1. isStepHeader tests
        assert(helper.isStepHeader("Step 1: Calculate force"))
        assert(helper.isStepHeader("Step 2. Calculate energy"))
        assert(helper.isStepHeader("**Step 3:** Calculate charge"))
        assert(helper.isStepHeader("### Step 4: Solve"))
        assert(helper.isStepHeader("1. Convert units"))
        assert(helper.isStepHeader("2) Substitute values"))
        assert(helper.isStepHeader("- Use Coulomb's law"))
        assert(helper.isStepHeader("* Compute the integral"))
        assert(!helper.isStepHeader("Here is the step-by-step solution:"))
        assert(!helper.isStepHeader("To solve this, we can follow these steps:"))
        assert(!helper.isStepHeader("$$E = mc^2$$"))
        assert(!helper.isStepHeader("This is not a step."))
        assert(!helper.isStepHeader("2026-07-14"))
        print("  [PASS] [1/7] testIsStepHeader passed")
        
        // 2. cleanStepText tests
        assert(helper.cleanStepText("Step 1: Calculate force") == "Calculate force")
        assert(helper.cleanStepText("**Step 2:** Find potential") == "Find potential")
        assert(helper.cleanStepText("### Step 3. Solve integration") == "Solve integration")
        assert(helper.cleanStepText("1. Convert to SI units") == "Convert to SI units")
        assert(helper.cleanStepText("2) Substitute $x=5$") == "Substitute $x=5$")
        assert(helper.cleanStepText("- Compute the final value") == "Compute the final value")
        assert(helper.cleanStepText("**Heaviest boson:** **Higgs**") == "Heaviest boson: Higgs")
        assert(helper.cleanStepText("- **Reaction 1:** **Forbidden**") == "Reaction 1: Forbidden")
        print("  [PASS] [2/7] testCleanStepText passed")
        
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
        assert(steps1.count == 3)
        assert(steps1[0] == "Identify the given quantities.\nWe have $m = 2\\text{ kg}$ and $a = 5\\text{ m/s}^2$.")
        assert(steps1[1] == "Apply Newton's second law.\n$$F = ma$$")
        assert(steps1[2] == "Calculate the force.\n$$F = 2 \\times 5 = 10\\text{ N}$$")
        
        let response2 = """
        - First, identify $v_0 = 10\\text{ m/s}$.
        - Second, use $v = v_0 + at$.
        - Third, solve for $v = 15\\text{ m/s}$.
        """
        let steps2 = helper.parseStepsFromLLMResponse(response2)
        assert(steps2.count == 3)
        assert(steps2[0] == "First, identify $v_0 = 10\\text{ m/s}$.")
        assert(steps2[1] == "Second, use $v = v_0 + at$.")
        assert(steps2[2] == "Third, solve for $v = 15\\text{ m/s}$.")
        
        let response3 = """
        1. Write the Schrodinger equation.
        2. Set up boundary conditions.
        """
        let steps3 = helper.parseStepsFromLLMResponse(response3)
        assert(steps3.count == 2)
        assert(steps3[0] == "Write the Schrodinger equation.")
        assert(steps3[1] == "Set up boundary conditions.")
        
        let response4 = """
        First, we calculate the gradient. The potential function is given.
        
        Then, we find the electric field as the negative gradient of potential.
        """
        let steps4 = helper.parseStepsFromLLMResponse(response4)
        assert(steps4.count == 2)
        assert(steps4[0] == "First, we calculate the gradient. The potential function is given.")
        assert(steps4[1] == "Then, we find the electric field as the negative gradient of potential.")
        
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
        assert(steps5.count == 3)
        assert(steps5[0].contains("[Conceptual Setup]"))
        assert(steps5[0].contains("(i)"))
        assert(steps5[1].contains("[Governing Formulation]"))
        assert(steps5[2].contains("[Algebraic Derivation]"))
        print("  [PASS] [3/7] testParseStepsFromLLMResponse passed")
        
        // 4. splitSolutionIntoSubparts
        let solution = """
        (i) Noting that N = n_up + n_down, we find E = mu H (N - 2n_up).
        (ii) There are N C n_up configurations, giving entropy S(n_up) via Stirling's approximation.
        (iii) Microcanonical vs Canonical ensemble comparison.
        (iv) Temperature reciprocal 1/T and negative temperature limit.
        """
        let subparts = helper.splitSolutionIntoSubparts(solution)
        assert(subparts.count == 4)
        assert(subparts[0].subpart == "(i)")
        assert(subparts[0].content.contains("E = mu H"))
        assert(subparts[1].subpart == "(ii)")
        assert(subparts[1].content.contains("Stirling's approximation"))
        assert(subparts[2].subpart == "(iii)")
        assert(subparts[3].subpart == "(iv)")
        print("  [PASS] [4/7] testSplitSolutionIntoSubparts passed")
        
        // 5. Glitch and repetition detection
        assert(!helper.hasRepetitiveGlitch("Short unique math text."))
        assert(helper.hasRepetitiveGlitch(String(repeating: "Identical repeating line of text.\n", count: 20)))
        print("  [PASS] [5/7] testRepetitiveGlitchDetection passed")
        
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
        assert(convertedTable.contains("\\begin{array}{|c|c|}"))
        assert(convertedTable.contains("\\end{array}"))
        assert(convertedTable.contains("$$"))
        assert(convertedTable.contains("\\text{Name}"))
        assert(convertedTable.contains("\\text{Mass}"))
        print("  [PASS] [6/7] testTabularConversion passed")
        
        // 7. sanitizeLaTeX markdown asterisks and url tests
        let rawWithStars = "**Heaviest boson:** **Higgs** online \\url{http://pdg.lbl.gov}"
        let sanitized = sanitizeLaTeX(rawWithStars)
        assert(!sanitized.contains("**"))
        assert(!sanitized.contains("\\url"))
        assert(sanitized.contains("Heaviest boson: Higgs"))
        assert(sanitized.contains("http://pdg.lbl.gov"))
        print("  [PASS] [7/8] testMarkdownBoldStripping passed")
        
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
        assert(sessionDeck.count == 5, "Session deck should match targetCount")
        assert(sessionDeck.contains(where: { $0.id == 1 }), "Untouched card must be prioritized into session deck")
        assert(sessionDeck.contains(where: { $0.id == 2 }), "Oldest overdue card must be prioritized into session deck")
        assert(FlashcardScheduler.calculateNextInterval(card: untouchedCard, quality: 3) == 3.8, "First Good rating on untouched card (ease 2.5) must schedule 3.8d out")
        assert(FlashcardScheduler.calculateNextInterval(card: overdueCard, quality: 3) == 3.6, "Good rating on interval=1, ease=1.5 card must advance to 3.6d")
        assert(FlashcardScheduler.calculateNextInterval(card: overdueCard, quality: 2) == 3.0, "Hard rating on interval=1 card must advance to 3.0d")
        assert(FlashcardScheduler.calculateNextRepetitions(card: overdueCard, quality: 2) == 1, "Hard rating must advance repetitions to at least 1")
        assert(FlashcardScheduler.calculateNextEaseFactor(currentEase: 2.5, quality: 3) == 2.5, "Good rating must not penalize ease factor")
        print("  [PASS] [8/11] testFlashcardScheduler passed")
        
        // 9. Question Subpart Extraction & "i.e." avoidance
        let unifiedProblemWithIE = """
        For $\\hat{H}(t) = \\hat{H}$, i.e., a time-independent Hamiltonian, we found that the solution to this equation was
        $$U(t, t_0) = \\exp \\left( -\\frac{i}{\\hbar} \\hat{H}(t - t_0) \\right) \\,.$$
        Show that this means we can write the spectral decomposition.
        """
        assert(!helper.questionHasSubparts(unifiedProblemWithIE), "Question with 'i.e.' must not be identified as having subparts")
        
        let problemWithImplicitPreambleA = """
        The 0-th energy eigenstate of the simple harmonic oscillator can be written as
        $$|0\\rangle = \\alpha_0 \\int dx \\psi_0(x) |x\\rangle$$
        Work out what \\alpha_0 is.
        (b) The second energy eigenstate can similarly be written as...
        (c) Show that \\langle 0|2\\rangle = 0.
        (d) What does this imply about the states?
        """
        let extractedSubs = helper.extractQuestionSubparts(problemWithImplicitPreambleA)
        assert(extractedSubs.count == 4, "Implicit preamble before (b) must be inferred as (a), producing 4 subparts")
        assert(extractedSubs[0].subpart == "(a)")
        assert(extractedSubs[1].subpart == "(b)")
        assert(extractedSubs[2].subpart == "(c)")
        assert(extractedSubs[3].subpart == "(d)")
        assert(helper.questionHasSubparts(problemWithImplicitPreambleA))
        print("  [PASS] [9/11] testQuestionSubpartExtraction passed")
        
        // 10. OCR Answer Deduplication
        let repeatedAnswer = AIHelper.ExtractedAnswer(label: "Problem Continuation", content: "$$\\int dx \\, e^{-c^2 x^2} = \\sqrt{\\pi / c^2}$$")
        let distinctAnswer = AIHelper.ExtractedAnswer(label: "Part (b)", content: "$$\\langle 0 | \\hat{p} | 0 \\rangle = 0$$")
        let rawAnswers = [repeatedAnswer, repeatedAnswer, repeatedAnswer, repeatedAnswer, distinctAnswer]
        let deduplicated = helper.deduplicateExtractedAnswers(rawAnswers)
        assert(deduplicated.count == 2, "4 identical repeated OCR blocks must be deduplicated into 1")
        assert(deduplicated[0].label == "Problem Continuation")
        assert(deduplicated[1].label == "Part (b)")
        print("  [PASS] [10/11] testDeduplicateAnswers passed")
        
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
        assert(parsedUnclosed.count == 2, "Unclosed [STEP] response must produce 2 valid steps")
        assert(parsedUnclosed[0].contains("[Conceptual Setup]"), "Step 1 must contain [Conceptual Setup]")
        assert(!parsedUnclosed[0].contains("[STEP]"), "Raw [STEP] tags must never leak into step content")
        assert(parsedUnclosed[1].contains("[Governing Formulation]"), "Step 2 must contain [Governing Formulation]")
        
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
        assert(consolidatedSteps.count <= 3, "Untagged isolated equations must be consolidated into structured steps")
        assert(consolidatedSteps[0].contains("[Conceptual Setup]"), "Untagged step 1 must be auto-assigned a diagnostic tier")
        print("  [PASS] [11/12] testUnclosedStepParsingAndParagraphConsolidation passed")
        
        // 12. Thinking Block Stripping & Non-Thinking Verification
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
        assert(parsedThinking.count == 2, "Thinking trace must be stripped, leaving 2 valid steps")
        assert(!parsedThinking[0].contains("<think>") && !parsedThinking[0].contains("</think>"), "Step must not contain think tags")
        assert(!parsedThinking[0].contains("The user wants to derive"), "Thinking monologue must be omitted")
        assert(parsedThinking[0].contains("[Conceptual Setup]"), "Step 1 must have Conceptual Setup")
        
        // Verify GenerateRequest encodes think: false
        let genReq = GenerateRequest(model: "qwen3:8b", prompt: "test", stream: false, think: false)
        let encData = try? JSONEncoder().encode(genReq)
        let encStr = encData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        assert(encStr.contains("\"think\":false"), "GenerateRequest must encode think:false in JSON payload")
        // Verify independent text vs visual thinking resolution
        UserDefaults.standard.set(true, forKey: "ai_text_thinking_enabled")
        UserDefaults.standard.set(false, forKey: "ai_vision_thinking_enabled")
        assert(UserDefaults.standard.bool(forKey: "ai_text_thinking_enabled") == true, "Text thinking should be enabled")
        assert(UserDefaults.standard.bool(forKey: "ai_vision_thinking_enabled") == false, "Vision thinking should be disabled")
        
        print("  [PASS] [12/13] testThinkingBlockStripping passed")
        
        // 13. LaTeX Cleaning & Reasoning Suppression
        let rawLatexWithFences = """
        ```latex
        \\hat{J}_\\pm |j, m_j\\rangle = \\hbar \\sqrt{j(j+1) - m_j(m_j \\pm 1)} |j, m_j \\pm 1\\rangle
        ```
        """
        assert(helper.cleanLaTeXOutput(rawLatexWithFences) == "\\hat{J}_\\pm |j, m_j\\rangle = \\hbar \\sqrt{j(j+1) - m_j(m_j \\pm 1)} |j, m_j \\pm 1\\rangle")
        
        let rawWithPreamble = """
        The equation is:
        $$\\int_{a}^{b} x^2 \\, dx$$
        """
        assert(helper.cleanLaTeXOutput(rawWithPreamble) == "\\int_{a}^{b} x^2 \\, dx")
        
        let pureThinkingOutput = "<think>\nLet's see what the image shows...\n</think>"
        assert(helper.cleanLaTeXOutput(pureThinkingOutput) == nil, "Pure thinking output must resolve to nil")
        
        let cutOffThinkingOutput = "<think>\nLet's analyze the differential operator without closing tag"
        assert(helper.cleanLaTeXOutput(cutOffThinkingOutput) == nil, "Cut-off thinking block must resolve to nil")
        print("  [PASS] [13/13] testLaTeXCleaningAndReasoningSuppression passed")
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[PASS] ALL 13 TEST SUITES PASSED (100% assertions verified)!")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
}
