// Canonical "custom result UI" example.
//
// A tool returns `longpi.ui({ text, view })` — BOTH halves, explicitly:
//   • text — what the MODEL reads. A concise plain-text summary you write.
//   • view — what the USER sees. A small TSX tree the app renders with its own
//            components (nothing runs in the browser; it's data, not code).
//
// The two are independent: the model never sees the tree, so give it a clean
// summary while the user gets the rich table. Name the file `.tsx`.

interface Proc {
  pid: string;
  cpu: string;
  mem: string;
  command: string;
}

export default function (longpi: any) {
  longpi.registerTool({
    name: "top_processes",
    description: "Show the top processes by CPU usage as a table.",
    parameters: {
      type: "object",
      properties: {
        limit: { type: "integer", description: "How many rows to show (1-20, default 8).", default: 8 },
      },
    },
    async execute(args: { limit?: number }) {
      const limit = Math.min(Math.max(Number.isInteger(args.limit) ? args.limit! : 8, 1), 20);

      // longpi.run executes a real program on the machine and returns
      // { status, stdout, stderr } — the escape hatch when JS globals aren't enough.
      const { status, stdout, stderr } = await longpi.run("ps", [
        "-eo",
        "pid,pcpu,pmem,comm",
        "--sort=-pcpu",
      ]);

      if (status !== 0) {
        return longpi.ui({
          text: `Could not read processes: ${stderr || `ps exited with ${status}`}`,
          view: (
            <Card title="Process list unavailable">
              <Badge text="ps failed" tone="danger" />
              <Text>{stderr || `exit ${status}`}</Text>
            </Card>
          ),
        });
      }

      const rows: Proc[] = stdout
        .trim()
        .split("\n")
        .slice(1, limit + 1) // drop the header row
        .map((line: string) => {
          const [pid, cpu, mem, ...cmd] = line.trim().split(/\s+/);
          return { pid, cpu, mem, command: cmd.join(" ") };
        });

      return longpi.ui({
        // The model reads this — plain text it can reason over.
        text: rows.map((p) => `${p.command} (pid ${p.pid}): ${p.cpu}% CPU, ${p.mem}% MEM`).join("\n"),
        // The user sees this — the same data, rendered richly.
        view: (
          <Card title={`Top ${rows.length} processes by CPU`}>
            <Table
              columns={["PID", "CPU %", "MEM %", "Command"]}
              rows={rows.map((p) => [p.pid, p.cpu, p.mem, p.command])}
            />
          </Card>
        ),
      });
    },
  });
}
