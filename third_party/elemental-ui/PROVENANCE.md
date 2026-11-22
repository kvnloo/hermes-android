# elemental-ui packs: provenance

Generated from https://github.com/kvnloo/elemental-ui at commit
`3130a17cd321e8159a8f74f68325e85103a12663` with:

```bash
python3 tools/elemental.py validate
python3 tools/elemental.py generate --size 512 --out <dir>
```

Only the basecolor, normal and roughness maps are bundled. The generator is
deterministic; re-running it at that commit reproduces these SHA-256 hashes:

```
17366a249063a334959219c04f7a6868113873e2976d36f6e5b3ab77d8c9410d  geo.basalt.vesicular.v1/basecolor.png
9f4144b44ff99ab26576caeeae0a248c49718055eedf1d4fd2bf6fe04c18fcd3  geo.basalt.vesicular.v1/normal.png
1dd9fc0deba98583f6ed645f097065da6a4f2863f3bc025cc817b46fa3529d5b  geo.basalt.vesicular.v1/roughness.png
f88915d5370147399a57d7ec54056dae03da820468d2cc0f0600897f04f8cfad  geo.limestone.porous.v1/basecolor.png
5013aa25a985ee9396e50aafbd48ce4de2517d00672317c78af59b19ba959066  geo.limestone.porous.v1/normal.png
dbc174be740b1e19dd39db6bd70f1184acc0741f1e3526e556ffbab8b0a12447  geo.limestone.porous.v1/roughness.png
05ef015f7ecee8c2fb9a987625694b547a139cb8fa1e8d2600c9f84ce5b9aaf6  geo.slate.layered.v1/basecolor.png
75cca9a370341b4378a14f1b54fb62b3aad965004e15205a0a117154001c16f6  geo.slate.layered.v1/normal.png
e4c26781a0d202ae9c466a7fa7dbc61dfa946d41abd70310b311b950f1454e91  geo.slate.layered.v1/roughness.png
```
