// ignore_for_file: constant_identifier_names

/// Centralized Environment & Secret Configuration for Allora.
///
/// All secret API keys, server URLs, and sensitive credentials should be
/// retrieved through [EnvConfig] rather than hardcoded in source files.
///
/// Values can be supplied at build time via `--dart-define=KEY=val`,
/// `--dart-define-from-file=.env`, or loaded from `.env` in local environments.
class EnvConfig {
  EnvConfig._();

  /// Supabase project URL (`SUPABASE_URL`).
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://rwkebciwvsmavsigdrfa.supabase.co',
  );

  /// Supabase Anon/Public JWT Key (`SUPABASE_ANON_KEY`).
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ3a2ViY2l3dnNtYXZzaWdkcmZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA3NjI2NzksImV4cCI6MjA5NjMzODY3OX0.8E1Y4G23Lwojda86Z-R5ZSUFrwDk3MTjysWwxNpRbAM',
  );

  /// Matrix Homeserver base URL (`MATRIX_HOMESERVER_URL`).
  static const String matrixHomeserverUrl = String.fromEnvironment(
    'MATRIX_HOMESERVER_URL',
    defaultValue: 'https://matrix.allorachat.app',
  );

  /// Legacy Synapse registration secret (`SYNAPSE_ADMIN_SECRET`).
  /// Note: Kept only for legacy migration fallback. New provisioning uses
  /// Supabase Edge Functions (`allora-provision`).
  static const String synapseAdminSecret = String.fromEnvironment(
    'SYNAPSE_ADMIN_SECRET',
    defaultValue: 'AlloraSuperSecret2026',
  );

  /// Gemini LLM API Key (`GEMINI_API_KEY`).
  /// Note: In production mobile apps, LLM calls are proxied through Supabase
  /// Edge Functions (`allora-ai`) so the key remains secret on the server.
  /// This key is available for local testing and direct SDK experimentation.
  static const String geminiApiKey = String.fromEnvironment(
    'GEMINI_API_KEY',
    defaultValue: '',
  );

  /// Google Web Client ID for Google Sign-In (`GOOGLE_WEB_CLIENT_ID`).
  static const String googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue:
        '350278193163-j6qc8oi5uk8q8l6ba4nu7op8et2nu30e.apps.googleusercontent.com',
  );

  /// Returns true if [geminiApiKey] is present.
  static bool get hasGeminiApiKey => geminiApiKey.isNotEmpty;
}
