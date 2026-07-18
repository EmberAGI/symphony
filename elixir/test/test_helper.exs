# The deterministic non-live gate must produce the same result in any ambient
# role environment. Runtime provider overrides leak from Octo role processes and
# would silently flip provider-dependent defaults, so the suite always starts
# from the unset baseline; tests that exercise the overrides set and restore
# them explicitly.
System.delete_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
System.delete_env("OCTO_RUNTIME_WORKER_PROVIDER")

ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/non_live_linear_client.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/claude_shim_fixture.exs", __DIR__)
Code.require_file("support/agent_profile_fixture.exs", __DIR__)
SymphonyElixir.TestAgentProfileFixture.install!()
