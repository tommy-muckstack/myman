// The macOS entrypoint and committed native companion remain byte-identical.
if (process.platform === 'linux') await import('./linux/bundle/app-server.mjs');
else await import('../src/Resources/BrainCompanion/app-server.mjs');
