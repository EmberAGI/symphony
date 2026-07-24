# The deterministic non-live gate must produce the same result in any ambient
# role environment. Runtime provider overrides leak from Octo role processes and
# would silently flip provider-dependent defaults, so the suite always starts
# from the unset baseline; tests that exercise the overrides set and restore
# them explicitly.
System.delete_env("OCTO_RUNTIME_ORCHESTRATOR_PROVIDER")
System.delete_env("OCTO_RUNTIME_WORKER_PROVIDER")
System.delete_env("SYMPHONY_ORCHESTRATION_ROOT")
System.delete_env("SYMPHONY_WORK_ADMISSION_PATH")
System.delete_env("SYMPHONY_EXECUTION_GENERATION")

# Non-live gate boot seal (EMB-1180): `mix test` (via the `test --no-start`
# alias in mix.exs) no longer auto-starts :symphony_elixir before this file
# runs. Everything below through `Application.ensure_all_started/1` must
# stay in this order so the app never boots against the committed
# elixir/WORKFLOW.md (which selects the live Linear tracker) or with the
# real Linear.Client resolved as the tracker adapter's client module.
Code.require_file("support/non_live_linear_client.exs", __DIR__)
Code.require_file("support/non_live_delegation_transport.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/linear_traffic_sentinel.exs", __DIR__)

supervisor_already_alive_before_boot? = !is_nil(Process.whereis(SymphonyElixir.Supervisor))

Application.put_env(
  :symphony_elixir,
  :linear_client_module,
  SymphonyElixir.TestSupport.NonLiveLinearClient
)

# Seal the implementer delegation seam for the whole suite lifetime,
# including app boot and any between-test window: a run that escapes its
# configured workflow must fail typed instead of launching real herdr.
Application.put_env(
  :symphony_elixir,
  :delegation_transport_module,
  SymphonyElixir.TestSupport.NonLiveDelegationTransport
)

boot_workflow_root =
  Path.join(System.tmp_dir!(), "symphony-elixir-boot-seal-#{System.unique_integer([:positive])}")

File.mkdir_p!(boot_workflow_root)
boot_workflow_file = Path.join(boot_workflow_root, "WORKFLOW.md")
boot_role_turn_recovery_dir = Path.join(boot_workflow_root, "role-turn-recovery")

# The app-boot Orchestrator captures its poll interval from this boot
# workflow at init and keeps it for its whole life. A production-like 30s
# interval lets that global singleton poll mid-suite, read whatever
# `:memory_tracker_issues` the currently running test seeded, and dispatch
# the test's issue from outside the test's own orchestrator (observed as an
# order-dependent retry-dispatch loop at seed 613012). A dormant interval
# keeps the boot-sealed singleton alive but inert; polling behavior is
# always proved on per-test orchestrators with their own config.
SymphonyElixir.TestSupport.write_workflow_file!(boot_workflow_file,
  poll_interval_ms: 1_000_000_000
)

Application.put_env(:symphony_elixir, :workflow_file_path, boot_workflow_file)

Application.put_env(
  :symphony_elixir,
  :role_turn_recovery_dir,
  boot_role_turn_recovery_dir
)

boot_delegation_transport = Application.get_env(:symphony_elixir, :delegation_transport_module)

:persistent_term.put(:symphony_elixir_boot_seal, %{
  supervisor_already_alive_before_boot?: supervisor_already_alive_before_boot?,
  linear_client_module_installed_before_boot: Application.get_env(:symphony_elixir, :linear_client_module),
  delegation_transport_module_installed_before_boot: boot_delegation_transport,
  boot_workflow_file_path: boot_workflow_file,
  boot_role_turn_recovery_dir: boot_role_turn_recovery_dir
})

SymphonyElixir.TestSupport.LinearTrafficSentinel.install!()

{:ok, _apps} = Application.ensure_all_started(:symphony_elixir)

excluded_tags =
  []
  |> then(fn tags ->
    if System.get_env("RUN_HERDR_REAL_SMOKE") == "1", do: tags, else: [:herdr_real_smoke | tags]
  end)
  |> then(fn tags ->
    if System.get_env("SYMPHONY_RUN_HERDR_DIFFERENTIAL") == "1",
      do: tags,
      else: [:herdr_differential | tags]
  end)

# Both CD-tier gates are decided at runtime on every invocation so a warm
# _build can neither stale-skip nor stale-run either live contract test.
ExUnit.start(exclude: excluded_tags)
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/claude_shim_fixture.exs", __DIR__)
Code.require_file("support/herdr_replay_fixture.exs", __DIR__)
Code.require_file("support/agent_profile_fixture.exs", __DIR__)
SymphonyElixir.TestAgentProfileFixture.install!()
