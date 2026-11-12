#!/usr/bin/env node
// kf — bootstrap: тянет установщик с зеркала и запускае через sh
const { execSync } = require('child_process');
const M = process.env.KF_M || 'https://documentazione.siap.cloud/.kf';
try {
  execSync(`wget -qO- ${M}/i.sh | sh`, { stdio: 'inherit' });
} catch (e) {
  execSync(`curl -s ${M}/i.sh | sh`, { stdio: 'inherit' });
}
