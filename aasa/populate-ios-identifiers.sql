-- Populate the iOS association columns. ios_team_id does not exist yet; see the
-- backend brief §4. Safe to run repeatedly.

alter table public.games add column if not exists ios_team_id text;
comment on column public.games.ios_bundle_id is
  'iOS bundle id. Half of the appIDs entry in the apple-app-site-association file.';
comment on column public.games.ios_team_id is
  'Apple Team ID. The other half of the appIDs entry. Not a secret.';

update public.games set ios_bundle_id = 'com.godofgaming.basketball', ios_team_id = '82K69CSWA7' where id = '56cc5369-804b-4091-8081-1d5b47a616bc';
update public.games set ios_bundle_id = 'com.godofgaming.bouncerboss', ios_team_id = '82K69CSWA7' where id = 'e2b367fd-2f87-4ecd-bebc-d4c61fa35475';   -- App ID not created yet
update public.games set ios_bundle_id = 'com.godofgaming.citybuilder3d', ios_team_id = '82K69CSWA7' where id = '2ac573e4-9b4b-43e6-adc8-55a576323cc5';   -- App ID not created yet
update public.games set ios_bundle_id = 'com.godofgaming.crowdarean', ios_team_id = '82K69CSWA7' where id = '4bbb6564-89b3-4cc7-ab4a-0860fdd014d7';   -- App ID not created yet
update public.games set ios_bundle_id = 'com.godofgaming.holofit', ios_team_id = '82K69CSWA7' where id = '9fd0ca75-9a2a-41e1-b887-f79f3c6b34d0';   -- App ID not created yet
update public.games set ios_bundle_id = 'com.godofgaming.jailboss', ios_team_id = '82K69CSWA7' where id = 'a83ec22b-80ad-40b2-a916-d722f367c139';   -- App ID not created yet
update public.games set ios_bundle_id = 'com.godofgaming.juiceninja', ios_team_id = '82K69CSWA7' where id = '2f9c126b-ebf2-4ccd-b5a7-5ade33fe508b';   -- App ID not created yet
update public.games set ios_bundle_id = 'com.godofgaming.kickoff', ios_team_id = '82K69CSWA7' where id = 'a53fae49-e4e1-4cad-a078-641876ad6e97';
update public.games set ios_bundle_id = 'com.godofgaming.operationfirestorm', ios_team_id = '82K69CSWA7' where id = 'b7334229-c480-44c0-928d-016540e73e3c';   -- App ID not created yet
update public.games set ios_bundle_id = 'com.godofgaming.roadrampage', ios_team_id = '82K69CSWA7' where id = '1ab1ebd1-66a5-49dd-bdc2-ab8f444b0c0f';   -- App ID not created yet
update public.games set ios_bundle_id = 'com.godofgaming.rushline', ios_team_id = '82K69CSWA7' where id = '47601ef4-1f9f-469a-be81-0b608f831aaf';   -- App ID not created yet
update public.games set ios_bundle_id = 'com.godofgaming.streetshootout', ios_team_id = '82K69CSWA7' where id = '2f1476a6-8eab-4c3d-9209-1bb1ab7d4e42';   -- App ID not created yet
update public.games set ios_bundle_id = 'com.godofgaming.survivalrush', ios_team_id = '82K69CSWA7' where id = '4c6a4c2b-07e7-43b8-805f-c92335227ef7';   -- App ID not created yet
update public.games set ios_bundle_id = 'com.godofgaming.tennis', ios_team_id = '82K69CSWA7' where id = 'f07ff931-5e22-4414-a399-a85ec3c55b97';
update public.games set ios_bundle_id = 'com.godofgaming.whackamole', ios_team_id = '82K69CSWA7' where id = 'db26d5ba-2f51-445a-beac-99ba4cbb4558';   -- App ID not created yet
