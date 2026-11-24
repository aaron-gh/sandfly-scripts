local manifest = {
  id = 'keyhub-keys',
  name = 'Keyhub keys',
  version = '1.0',
  author = 'Aaron Hewitt',
  minApiVersion = 3,
  testedApiVersion = 6,
  description = 'In Keyhub, every key goes to Keyhub: typing searches, the trackpad moves between items and SandFly reads the item Keyhub moves to. The keys of Turn SandFly keyboard input on or off still work, and stop this until Keyhub is opened again.',
  apps = { 'com.keyhub' },
  permissions = { 'input' },
}

sf.keys.passAll()
-- SandFly signature: MEUCIAW/bJEd7cfO6T9xyQ12GYCb1ARBnEtVGb0pBTgqum7mAiEA2Wlf5BP2LA3NxvTmCLyIkvZQ7AwJcc9FLVVzhcieVAI=
