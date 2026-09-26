if (process.argv[2] === '--fire') {
  const { fire } = await import('./timers.mjs');
  const [, , , kind, id, generation, flag, seconds] = process.argv;
  await fire(kind, id, generation, flag === '--wait' ? seconds : 0);
} else {
  const { work } = await import('./service.mjs');
  await work(process.argv[2]);
}
