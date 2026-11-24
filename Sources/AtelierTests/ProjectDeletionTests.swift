@testable import Atelier
import Testing

/// Delete Project's confirmation about the project's jobs (`ProjectDeletion`): counts by state,
/// and the destructive button that says the jobs go too.
@Suite(.tags(.smoke))
struct ProjectDeletionTests {
  @Test func noJobsSayNothing() {
    #expect(ProjectDeletion.jobsMessage(project: "A", running: 0, waiting: 0) == nil)
    #expect(ProjectDeletion.confirmTitle(jobCount: 0) == "Delete Project")
  }

  @Test func countsByState() {
    #expect(ProjectDeletion.jobsMessage(project: "A", running: 1, waiting: 2) == "1 job for “A” is running and 2 are waiting. Deleting the project cancels them.")
    #expect(ProjectDeletion.jobsMessage(project: "A", running: 2, waiting: 1) == "2 jobs for “A” are running and 1 is waiting. Deleting the project cancels them.")
    #expect(ProjectDeletion.jobsMessage(project: "A", running: 1, waiting: 0) == "1 job for “A” is running. Deleting the project cancels it.")
    #expect(ProjectDeletion.jobsMessage(project: "A", running: 0, waiting: 3) == "3 jobs for “A” are waiting. Deleting the project cancels them.")
    #expect(ProjectDeletion.jobsMessage(project: "A", running: 0, waiting: 1) == "1 job for “A” is waiting. Deleting the project cancels it.")
  }

  @Test func withJobsTheButtonSaysTheyGo() {
    #expect(ProjectDeletion.confirmTitle(jobCount: 1) == "Cancel Jobs and Delete")
    #expect(ProjectDeletion.confirmTitle(jobCount: 3) == "Cancel Jobs and Delete")
  }
}
