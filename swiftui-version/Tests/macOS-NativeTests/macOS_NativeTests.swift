import Testing
@testable import macOS_Native

struct MacOSNativeTests {
    
    @Test @MainActor
    func isStepHeader() {
        let helper = AIHelper.shared
        
        // Positive cases
        #expect(helper.isStepHeader("Step 1: Calculate force"))
        #expect(helper.isStepHeader("Step 2. Calculate energy"))
        #expect(helper.isStepHeader("**Step 3:** Calculate charge"))
        #expect(helper.isStepHeader("### Step 4: Solve"))
        #expect(helper.isStepHeader("1. Convert units"))
        #expect(helper.isStepHeader("2) Substitute values"))
        #expect(helper.isStepHeader("- Use Coulomb's law"))
        #expect(helper.isStepHeader("* Compute the integral"))
        
        // Negative cases
        #expect(!helper.isStepHeader("Here is the step-by-step solution:"))
        #expect(!helper.isStepHeader("To solve this, we can follow these steps:"))
        #expect(!helper.isStepHeader("$$E = mc^2$$"))
        #expect(!helper.isStepHeader("This is not a step."))
        #expect(!helper.isStepHeader("2026-07-14"))
    }
    
    @Test @MainActor
    func cleanStepText() {
        let helper = AIHelper.shared
        
        #expect(helper.cleanStepText("Step 1: Calculate force") == "Calculate force")
        #expect(helper.cleanStepText("**Step 2:** Find potential") == "Find potential")
        #expect(helper.cleanStepText("### Step 3. Solve integration") == "Solve integration")
        #expect(helper.cleanStepText("1. Convert to SI units") == "Convert to SI units")
        #expect(helper.cleanStepText("2) Substitute $x=5$") == "Substitute $x=5$")
        #expect(helper.cleanStepText("- Compute the final value") == "Compute the final value")
    }
    
    @Test @MainActor
    func parseStepsFromLLMResponse() {
        let helper = AIHelper.shared
        
        // Test case 1: Standard structured response with intros/outros
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
        #expect(steps1.count == 3)
        #expect(steps1[0] == "Identify the given quantities.\nWe have $m = 2\\text{ kg}$ and $a = 5\\text{ m/s}^2$.")
        #expect(steps1[1] == "Apply Newton's second law.\n$$F = ma$$")
        #expect(steps1[2] == "Calculate the force.\n$$F = 2 \\times 5 = 10\\text{ N}$$")
        
        // Test case 2: Bullet points
        let response2 = """
        - First, identify $v_0 = 10\\text{ m/s}$.
        - Second, use $v = v_0 + at$.
        - Third, solve for $v = 15\\text{ m/s}$.
        """
        let steps2 = helper.parseStepsFromLLMResponse(response2)
        #expect(steps2.count == 3)
        #expect(steps2[0] == "First, identify $v_0 = 10\\text{ m/s}$.")
        #expect(steps2[1] == "Second, use $v = v_0 + at$.")
        #expect(steps2[2] == "Third, solve for $v = 15\\text{ m/s}$.")
        
        // Test case 3: Numbered list
        let response3 = """
        1. Write the Schrodinger equation.
        2. Set up boundary conditions.
        """
        let steps3 = helper.parseStepsFromLLMResponse(response3)
        #expect(steps3.count == 2)
        #expect(steps3[0] == "Write the Schrodinger equation.")
        #expect(steps3[1] == "Set up boundary conditions.")
        
        // Test case 4: Fallback paragraph splitting (no headers or bullet points)
        let response4 = """
        First, we calculate the gradient. The potential function is given.
        
        Then, we find the electric field as the negative gradient of potential.
        """
        let steps4 = helper.parseStepsFromLLMResponse(response4)
        #expect(steps4.count == 2)
        #expect(steps4[0] == "First, we calculate the gradient. The potential function is given.")
        #expect(steps4[1] == "Then, we find the electric field as the negative gradient of potential.")
    }
}
