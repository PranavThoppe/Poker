import Foundation

/// Supabase project credentials for REST API calls.
/// Replace placeholders after creating a project at https://supabase.com.
enum SupabaseConstants {
    static let projectURL = "https://vyysmjvojjrwqjvobvfn.supabase.co"
    /// Supabase's current public client key. The game Edge Function validates
    /// `sb_publishable_…` keys; legacy JWT-shaped anon keys are rejected.
    static let anonKey = "sb_publishable_saZNPJbREI6CIt_mv7t7Lg_W3-Y3db_"
}
