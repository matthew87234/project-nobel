import XCTest
@testable import macOS_Native

final class macOS_NativeTests: XCTestCase {
    
    @MainActor
    func testIsStepHeader() {
        let helper = AIHelper.shared
        
        // Positive cases
        XCTAssertTrue(helper.isStepHeader("Step 1: Calculate force"))
        XCTAssertTrue(helper.isStepHeader("Step 2. Calculate energy"))
        XCTAssertTrue(helper.isStepHeader("**Step 3:** Calculate charge"))
        XCTAssertTrue(helper.isStepHeader("### Step 4: Solve"))
        XCTAssertTrue(helper.isStepHeader("1. Convert units"))
        XCTAssertTrue(helper.isStepHeader("2) Substitute values"))
        XCTAssertTrue(helper.isStepHeader("- Use Coulomb's law"))
        XCTAssertTrue(helper.isStepHeader("* Compute the integral"))
        
        // Negative cases
        XCTAssertFalse(helper.isStepHeader("Here is the step-by-step solution:"))
        XCTAssertFalse(helper.isStepHeader("To solve this, we can follow these steps:"))
        XCTAssertFalse(helper.isStepHeader("$$E = mc^2$$"))
        XCTAssertFalse(helper.isStepHeader("This is not a step."))
        XCTAssertFalse(helper.isStepHeader("2026-07-14"))
    }
    
    @MainActor
    func testCleanStepText() {
        let helper = AIHelper.shared
        
        XCTAssertEqual(helper.cleanStepText("Step 1: Calculate force"), "Calculate force")
        XCTAssertEqual(helper.cleanStepText("**Step 2:** Find potential"), "Find potential")
        XCTAssertEqual(helper.cleanStepText("### Step 3. Solve integration"), "Solve integration")
        XCTAssertEqual(helper.cleanStepText("1. Convert to SI units"), "Convert to SI units")
        XCTAssertEqual(helper.cleanStepText("2) Substitute $x=5$"), "Substitute $x=5$")
        XCTAssertEqual(helper.cleanStepText("- Compute the final value"), "Compute the final value")
    }
    
    @MainActor
    func testParseStepsFromLLMResponse() {
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
        XCTAssertEqual(steps1.count, 3)
        XCTAssertEqual(steps1[0], "Identify the given quantities.\nWe have $m = 2\\text{ kg}$ and $a = 5\\text{ m/s}^2$.")
        XCTAssertEqual(steps1[1], "Apply Newton's second law.\n$$F = ma$$")
        XCTAssertEqual(steps1[2], "Calculate the force.\n$$F = 2 \\times 5 = 10\\text{ N}$$")
        
        // Test case 2: Bullet points
        let response2 = """
        - First, identify $v_0 = 10\\text{ m/s}$.
        - Second, use $v = v_0 + at$.
        - Third, solve for $v = 15\\text{ m/s}$.
        """
        let steps2 = helper.parseStepsFromLLMResponse(response2)
        XCTAssertEqual(steps2.count, 3)
        XCTAssertEqual(steps2[0], "First, identify $v_0 = 10\\text{ m/s}$.")
        XCTAssertEqual(steps2[1], "Second, use $v = v_0 + at$.")
        XCTAssertEqual(steps2[2], "Third, solve for $v = 15\\text{ m/s}$.")
        
        // Test case 3: Numbered list
        let response3 = """
        1. Write the Schrodinger equation.
        2. Set up boundary conditions.
        """
        let steps3 = helper.parseStepsFromLLMResponse(response3)
        XCTAssertEqual(steps3.count, 2)
        XCTAssertEqual(steps3[0], "Write the Schrodinger equation.")
        XCTAssertEqual(steps3[1], "Set up boundary conditions.")
        
        // Test case 4: Fallback paragraph splitting (no headers or bullet points)
        let response4 = """
        First, we calculate the gradient. The potential function is given.
        
        Then, we find the electric field as the negative gradient of potential.
        """
        let steps4 = helper.parseStepsFromLLMResponse(response4)
        XCTAssertEqual(steps4.count, 2)
        XCTAssertEqual(steps4[0], "First, we calculate the gradient. The potential function is given.")
        XCTAssertEqual(steps4[1], "Then, we find the electric field as the negative gradient of potential.")
    }
}
