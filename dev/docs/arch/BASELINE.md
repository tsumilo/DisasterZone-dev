# Baseline: known failures on rf/arch @ 9c10f98 (= disasterzone 9466997)

Selection run of 212 suite runs on 12 Oct 2026 (DZ_TEST_SLOTS=3). 196 passed, these 16 failed. They fail on the base already: only NEW failures count. The release-only scale suite (scale/test_raid_night.py) was not run.

```
atlas__test_atlas                             rc=1    21s  -- test_atlas.py: 26 case(s), 25 passed, 1 failed (19.2s)
      FAIL tab_sits_after_my_bis_and_opens_on_the_guild_phase_raid (4.49s)
boot-ui__test_broad                           rc=1     6s  -- test_broad.py: 1 case(s), 0 passed, 1 failed (5.5s)
      FAIL broad_session_all_windows_then_report (5.36s)
boot-ui__test_council_ui                      rc=1    15s  -- test_council_ui.py: 15 case(s), 14 passed, 1 failed (13.4s)
      FAIL request_sync_button_real_council (0.34s)
boot-ui__test_demo                            rc=1    10s  -- test_demo.py: 5 case(s), 3 passed, 2 failed (9.2s)
      FAIL demo_toggle_repeatedly_changes_nothing_saved_and_sends_nothing (5.63s)
      FAIL demo_works_without_a_guild_and_sends_nothing (1.01s)
boot-ui__test_settings                        rc=1    17s  -- test_settings.py: 12 case(s), 11 passed, 1 failed (16.2s)
      FAIL minimap_toggle_hides_and_shows_the_button (1.15s)
boot-ui__test_mybis                           rc=1    34s  -- test_mybis.py: 19 case(s), 17 passed, 2 failed (30.8s)
      FAIL spec_dropdown_and_auto_detect (0.29s)
      FAIL uncached_item_names_fill_in_after_load (0.73s)
offspec__test_offspec                         rc=1    64s  -- off-spec lists (Addendum H): 11 case(s), 10 passed, 1 failed
      FAIL my_bis_switch_picker_and_remove: 
patch__test_patch_boot                        rc=1   314s  -- test_patch_boot.py: 24 case(s), 23 passed, 1 failed (297.6s)
      FAIL every_file_from_the_patch (9.28s)
patch__test_release_tool                      rc=1   157s  -- test_release_tool.py: 10 case(s), 9 passed, 1 failed (139.3s)
      FAIL selftest_runs_the_whole_addon_from_the_store_on_the_development_copy (3.54s)
raidplan__test_raidplan_leaders               rc=1    29s  -- test_raidplan_leaders.py: 11 case(s), 10 passed, 1 failed (26.5s)
      FAIL a_raid_leader_gets_no_loot_council_data (1.68s)
rollclose__test_rollclose                     rc=1    45s  -- roll popups close (Addendum C, end to end): 15 case(s), 13 passed, 2 failed
      FAIL a3_dungeon_party_master_looter_hand_out: Bob
      FAIL a4_cdloot_give_in_a_dungeon_party_master_loot: Carol-Thunderstrike: eval:1: attempt to index field 'frame' (a nil value)
strategy__test_strategy_3d.s1of2              rc=1    61s  -- test_strategy_3d.py: 14 case(s), 13 passed, 1 failed (57.5s)
      FAIL kiljaeden_stands_in_the_backdrop_under_the_whole_room (2.64s)
strategy__test_strategy_3d.s2of2              rc=1    63s  -- test_strategy_3d.py: 13 case(s), 12 passed, 1 failed (59.2s)
      FAIL a_big_model_is_hidden_part_by_part_and_you_swim_in_its_pool (4.34s)
strategy__test_standins_gen                   rc=1   281s  -- stand-in generator: 17 case(s), 14 passed, 3 failed (271.1s)
      FAIL test_shipped_file_has_the_contract_shape (0.06s)
      FAIL test_every_shipped_data_file_has_the_contract_shape_and_the_toc_loads_it (0.45s)
      FAIL test_shipped_file_is_what_the_generator_writes (1.70s)
sync__test_sync_traffic.s2of2                 rc=1    41s  -- 40-member guild traffic: 0 passed, 1 failed (h_slow_roster_council_member_in_login_wave)
      FAIL h_slow_roster_council_member_in_login_wave (37.6s)
ui-dungeon__test_ui_dungeon                   rc=1    29s  -- ui / dungeon mode + popup closing: 10 case(s), 9 passed, 1 failed
      FAIL party_roll_end_to_end_leader_awards_through_the_roll: {'Alice': True, 'Bob': False, 'Carol': False, 'Dave': False, 'Erin': False}
```
