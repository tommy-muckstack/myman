// The macOS entrypoint and committed native companion remain byte-identical.
if (process.platform === 'linux') await import('./linux/bundle/app-server.mjs');
else if (process.platform === 'darwin') await import('../src/Resources/BrainCompanion/app-server.mjs');
else {
  // MCP stdout is reserved for protocol messages; startup errors go to stderr.
  process.stderr.write(JSON.stringify({ok:false,error:{code:'unsupported_on_platform',message:`MyMan app tools do not support ${process.platform}.`}})+'\n');
  process.exitCode = 6;
}
