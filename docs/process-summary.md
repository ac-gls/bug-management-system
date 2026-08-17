# Complete Bug Fixing Process: Step-by-Step Guide

## Overview
This document provides a quick step-by-step guide for the entire bug fixing process, from initial bug identification in Azure DevOps to deployment of the bug fix in production. The process maintains synchronization between Azure DevOps tickets and GitHub issues throughout the workflow, ensures proper status management, and avoids processing already completed bugs.

## Phase 1: Bug Migration (ADO → GitHub)

### Step 1: Identify and Tag Bugs in Azure DevOps
- Review ADO bug tickets
- Add "MigrateToGitHub" tag to bugs ready for migration
- Ensure bugs have clear descriptions and steps to reproduce
- **Filter out already completed bugs** (Closed, Resolved, or Done status)
- Verify bugs are in "Active" or "New" state before tagging

### Step 2: Run Migration Script
```bash
# Execute migration process
herdr --session bug-migration
./start-bug-migration.sh

# Script automatically filters out completed bugs and only processes:
# - Bugs with "MigrateToGitHub" tag
# - Bugs in "Active" or "New" status
# - Bugs not already migrated (checks for existing GitHub issues)
```

### Step 3: Verify Migration Output
- GitHub issues created for each tagged ADO bug with ADO ticket references
- Resolution plans generated for each bug with cross-links to ADO
- Git branches created for each fix (fix/{BUG_ID}-{BRANCH})
- Comments posted in ADO tickets with links to corresponding GitHub issues
- **ADO ticket status updated to "In Progress" or similar**
- **GitHub issue status labeled as "migration-complete"**

## Phase 2: Developer Review and Preparation

### Step 4: Developer Reviews GitHub Issues
- Examine each created GitHub issue
- Review resolution plans and implementation branches
- Verify bug description and steps to reproduce
- **Check current status to ensure bug is not already completed**
- **Verify ADO ticket is still in an active state**
- **Confirm no other team is already working on the fix**

### Step 5: Developer Flags Issues as "Ready for Agent"
- Add "ready-for-agent" label to GitHub issues approved for fixing
- Ensure all necessary context is included in the issue
- Assign to appropriate team members if needed
- **Update ADO ticket status to "Ready for Development"**
- **Add comment in both systems confirming readiness for agent processing**

## Phase 3: Automated Bug Fixing Process

### Step 6: Run Bug Fixing Script
```bash
# Execute bug fixing process
herdr --session bug-fixing
./start-bug-fixing.sh "ready-for-agent"

# Script includes built-in checks:
# - Verifies GitHub issues are still in "ready-for-agent" status
# - Confirms ADO tickets are still active
# - Skips any issues/tickets that are already completed
# - Prevents duplicate processing of ongoing work
```

### Step 7: Automated Implementation Process
1. **Pre-Processing Status Check**:
   - Verify GitHub issue status is still "ready-for-agent"
   - Confirm ADO ticket is still active and not completed
   - Skip processing if either system shows completed status

2. **Parallel Test Development**:
   - Create failing tests that reproduce each bug
   - Set up unit, integration, and Playwright E2E tests
   - **Update GitHub issue status to "testing-in-progress"**
   - **Update ADO ticket status to "Testing"**

3. **TDD Implementation**:
   - Run failing tests to confirm bug reproduction
   - Implement minimal code to make tests pass
   - Refactor while keeping tests passing
   - Run all tests to ensure no regressions
   - **Update status to "implementation-in-progress" in both systems**

4. **Comprehensive Testing**:
   - Execute unit tests
   - Run integration tests
   - Perform Playwright E2E testing
   - Generate test results and documentation
   - **Update status to "testing-completed" in both systems**

5. **Automated Documentation**:
   - Post test results as comments on GitHub issues
   - Post test results as comments on corresponding ADO tickets
   - Add screenshots and logs for QA review in both systems
   - Add "tested" label to completed GitHub issues
   - Update ADO ticket status to "Tested" or similar
   - **Skip documentation if either system shows completed status**

6. **PR Creation**:
   - Automatically create pull requests for each fix
   - Link PRs to original GitHub issues
   - Reference ADO ticket numbers in PR descriptions
   - Add appropriate labels and descriptions
   - **Update status to "pr-created" in both systems**
   - **Skip PR creation if either system shows completed status**

## Phase 4: Developer Review, Merge, and Deployment Coordination

### Step 8: Developer Reviews Pull Requests
- Examine code changes in each PR
- Verify implementation follows resolution plan
- Check test results and documentation
- Review any QA feedback comments
- Add review comments to both GitHub PRs and corresponding ADO tickets
- **Verify status in both systems before review**
- **Skip review if either system shows completed status**
- **Update status to "review-in-progress" in both systems**

### Step 9: Developer Merges Approved PRs
- Merge approved pull requests to target branches
- Ensure proper merge strategy (squash, rebase, or merge commit)
- Verify CI/CD pipelines pass successfully
- **Update GitHub issue status to "merged"**
- **Update ADO ticket status to "Merged" or "Ready for Deployment"**
- **Skip merge if either system shows completed status**
- **Add merge confirmation comments in both systems**

### Step 10: Deployment to QA Environment
- Deploy merged changes to QA environment
- Verify deployment completed successfully
- Notify QA team of available fixes for testing
- Add deployment notification comments to both GitHub issues and ADO tickets
- Update ADO ticket status to "In QA"
- **Skip deployment if either system shows completed status**
- **Update status to "deployed-to-qa" in both systems**

## Phase 5: QA Validation

### Step 11: QA Team Receives Notification
- Receive notification of deployed fixes via GitHub and ADO
- Review GitHub issue comments and ADO ticket comments with test results
- Access QA environment for manual testing
- Cross-reference information between both systems
- **Verify status in both systems before beginning validation**
- **Skip validation if either system shows completed status**

### Step 12: QA Manual Validation
1. **Pre-Deployment Verification**:
   - Confirm all automated tests passed
   - Review test documentation and screenshots
   - Verify implementation follows resolution plan
   - **Update status to "qa-validation-started" in both systems**

2. **Post-Deployment Testing**:
   - Functional testing using provided steps
   - Regression testing to ensure no broken features
   - Cross-browser compatibility testing
   - Mobile responsiveness verification
   - Performance metrics validation
   - Security requirements checking
   - **Update status to "qa-testing-in-progress" in both systems**

### Step 13: QA Reporting
- **For Approved Fixes**: 
  - Add "qa-approved" label to GitHub issue
  - Comment on GitHub issue: "✅ QA validated - Ready for production deployment"
  - Add comment to corresponding ADO ticket: "✅ QA validated - Ready for production deployment"
  - Update ADO ticket status to "QA Approved"
  - **Update status to "qa-approved" in both systems**
  - **Skip reporting if either system shows completed status**
  
- **For Issues Requiring Changes**: 
  - Add "qa-feedback" label to GitHub issue
  - Comment on GitHub issue with detailed feedback including steps to reproduce and expected vs actual behavior
  - Add comment to corresponding ADO ticket with the same detailed feedback
  - Update ADO ticket status to "QA Feedback Required"
  - **Update status to "qa-feedback-required" in both systems**
  - **Skip reporting if either system shows completed status**

- **For Critical Issues**: 
  - Add "critical-bug" label to GitHub issue
  - Comment on GitHub issue with urgent priority flag
  - Add comment to corresponding ADO ticket with urgent priority flag
  - Update ADO ticket status to "Critical"
  - Escalate to project manager via both GitHub mentions and ADO notifications
  - **Update status to "critical" in both systems**
  - **Skip reporting if either system shows completed status**

## Phase 6: Production Deployment and Verification

### Step 14: Developer Monitors QA Approval
- Monitor GitHub issues for "qa-approved" labels
- Address any "qa-feedback" comments promptly
- Coordinate with QA team on critical issues
- **Verify status in both systems before proceeding**
- **Skip processing if either system shows completed status**

### Step 15: Production Deployment
- Deploy QA-approved fixes to production environment
- Monitor deployment process for any issues
- Verify production deployment success
- **Verify status in both systems before deployment**
- **Skip deployment if either system shows completed status**
- Add deployment confirmation comment to both GitHub issues and ADO tickets
- Update ADO ticket status to "Deployed to Production"
- Close GitHub issues with reference to ADO ticket resolution
- **Update status to "deployed-to-production" in both systems**

### Step 16: Post-Deployment Verification
- Confirm fixes working correctly in production
- Monitor application performance and stability
- Update ADO bug tickets with final resolution status
- Close GitHub issues with reference to ADO ticket resolution
- Add final verification comments to both GitHub issues and ADO tickets
- Archive completed work branches
- **Update status to "completed" in both systems**
- **Skip verification if either system already shows completed status**

## Phase 7: Process Completion and Documentation

### Step 17: Documentation and Reporting
- Update project documentation with changes
- Generate deployment reports
- Add summary comments to all relevant GitHub issues and ADO tickets
- Archive completed work branches
- Create cross-reference documentation linking GitHub issues to ADO tickets
- **Ensure all completed items show "completed" status in both systems**
- **Skip documentation for items already marked as completed**

### Step 18: Process Review
- Review overall process efficiency
- Identify areas for improvement
- Update scripts and procedures as needed
- Add process review comments to both GitHub and ADO for traceability
- **Verify no completed items were inadvertently processed**

## Key Automation Benefits

### Parallel Processing
- Multiple bugs investigated simultaneously using Herdr worktrees
- Test development and implementation run in parallel
- PR creation happens concurrently for all fixes

### Automated Quality Assurance
- TDD ensures code quality from the start
- Comprehensive test coverage (unit, integration, E2E)
- Automated documentation for QA review in both GitHub and ADO

### Streamlined Workflow
- Minimal manual intervention required
- Clear handoff points between automated processes and human review
- Standardized reporting and communication in both systems

### Intelligent Status Management
- Automatic status verification prevents processing completed bugs
- Real-time synchronization between GitHub and ADO
- Duplicate work prevention through status checking

### Complete Traceability
- Bidirectional linking between GitHub issues and ADO tickets
- Automatic status synchronization across both systems
- Comprehensive audit trail for compliance and reporting

### Status Management
- Real-time status updates in both GitHub and ADO
- Automatic filtering of completed bugs
- Prevention of duplicate processing
- Consistent state management across platforms

## Success Metrics

- **Time to Resolution**: Significantly reduced through parallel processing
- **Quality Assurance**: Comprehensive testing ensures bug-free deployments
- **Developer Productivity**: Automation handles repetitive tasks
- **QA Efficiency**: Clear documentation enables faster validation
- **Deployment Reliability**: Standardized process reduces deployment risks
- **Traceability**: Complete audit trail maintained in both GitHub and ADO
- **Communication**: All stakeholders kept informed through dual-system updates
- **Status Accuracy**: Real-time status synchronization prevents duplicate work
- **Process Integrity**: Built-in checks prevent processing of completed bugs

This end-to-end process ensures efficient, high-quality bug fixing with proper human oversight at critical decision points.