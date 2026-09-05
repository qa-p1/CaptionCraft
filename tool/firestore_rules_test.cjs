// Run against a local Firestore emulator only. Requires firebase and
// @firebase/rules-unit-testing (see docs/connected-services.md).
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { initializeTestEnvironment, assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { doc, collection, setDoc, getDoc, getDocs, deleteDoc } = require('firebase/firestore');

(async () => {
  const env = await initializeTestEnvironment({
    projectId: 'demo-captioncraft-vault',
    firestore: { host: '127.0.0.1', port: 8187,
      rules: readFileSync(resolve(__dirname, '../firestore.rules'), 'utf8') },
  });
  try {
    const alice = env.authenticatedContext('alice').firestore();
    const bob = env.authenticatedContext('bob').firestore();
    const guest = env.unauthenticatedContext().firestore();
    const path = 'users/alice/private/apiKeys';
    const envelope = { version: 1, revision: 1, nonce: 'n'.repeat(16),
      mac: 'm'.repeat(24), ciphertext: 'encrypted-test-fixture' };
    await assertSucceeds(getDoc(doc(alice, path)));
    await assertFails(getDoc(doc(guest, path)));
    await assertFails(setDoc(doc(bob, path), envelope));
    await assertSucceeds(setDoc(doc(alice, path), envelope));
    await assertSucceeds(getDoc(doc(alice, path)));
    await assertFails(getDoc(doc(bob, path)));
    await assertFails(getDoc(doc(guest, path)));
    await assertFails(getDocs(collection(alice, 'users/alice/private')));
    await assertFails(deleteDoc(doc(alice, path)));
    await assertFails(setDoc(doc(alice, path), envelope)); // stale revision
    await assertFails(setDoc(doc(alice, path), { ...envelope, revision: 2, secret: 'not-allowed' }));
    await assertFails(setDoc(doc(alice, path), { ...envelope, revision: 2, nonce: 'short' }));
    await assertFails(setDoc(doc(alice, path), { ...envelope, revision: 2, ciphertext: 'x'.repeat(4097) }));
    await assertSucceeds(setDoc(doc(alice, path), { ...envelope, revision: 2 }));
    await assertSucceeds(setDoc(doc(alice, 'users/alice'), { displayName: 'Alice' }));
    await assertFails(getDoc(doc(bob, 'users/alice')));
    const projectPath = 'projects/alice/user_projects/project1';
    await assertSucceeds(setDoc(doc(alice, projectPath), { ownerUid: 'alice', id: 'project1' }));
    await assertFails(getDoc(doc(bob, projectPath)));
    console.log('18 Firestore access and vault-shape checks passed (local emulator only).');
  } finally {
    await env.cleanup();
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
