local manifest = {
  id = 'keyhub-keys',
  name = 'Keyhub keys',
  version = '1.1',
  author = 'Aaron Hewitt',
  minApiVersion = 3,
  testedApiVersion = 6,
  description = 'On the Keyhub home screen, every key goes to Keyhub: typing searches, the trackpad moves between items and SandFly reads the item Keyhub moves to. The keys of Turn SandFly keyboard input on or off still work, and stop this until Keyhub is opened again. Keyhub settings and the reply screen use SandFly keys as other apps do.',
  apps = { { package = 'com.keyhub', activity = '.home.MainActivity' } },
  permissions = { 'input' },
}

sf.keys.passAll()
-- SandFly signature: MEYCIQCHxvDVAuKu6/D9wOUhfXcj80B+5YNz1jC8TYP1SGZX4AIhAJPPoiYuq85WXbQpz4xD48rg3eUPs4a+D/KL1RVexQ+4
