// The GENERIC agent driver (Claude Agent SDK). It runs ANY bound agent's turn, seeded by
// Rails with the agent's system prompt + tool manifest + optional output schema, and emits a
// JSONL event stream Rails ingests into the conversation event log.
//
// TOOLS OVER THE PIPE (stdio duplex — no HTTP): each manifest entry becomes an in-process MCP
// tool whose handler writes a `tool_request` to stdout and AWAITS a `tool_response` on stdin.
// The Ruby parent — already reading this process's stdout to drive the turn — runs the tool
// inline (as the chat's tenant) and writes the result back to stdin. One linear ping-pong in
// the same fiber that spawned us: no network, no token, no self-connection, no deadlock.
//
// Permission model: AUTO tools are allowlisted (run silently → their handler fires); a
// NEEDS_APPROVAL tool is exposed but NOT allowlisted, so canUseTool fires. SDK built-ins are
// likewise not allowlisted and are denied outright (this agent acts only through its roster).
//
// A gated call ENDS THE RUN. canUseTool emits a `needs_approval` line (tool name + args + tool_use_id) and
// denies with `interrupt: true`, so the SDK tears the run down and this process exits. Nothing is
// held open across the human wait: the frozen call is a durable row in Rails, and the conversation
// resumes by session id once the owner decides. See ApprovalsController.
//
// Protocol (stdout JSONL):  session · token · assistant · tool_request · needs_approval · result · error
//          (stdin JSONL):   tool_response {id, result, is_error}
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import {
  query,
  createSdkMcpServer,
  tool,
  type SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

const SERVER = "rbrun";

// cwd is the chat's workspace; the runner staged the skills under its .claude/.
const SKILLS_DIR = join(process.cwd(), ".claude", "skills");

// Whatever the runner staged into <workspace>/.claude/skills/ — read off the directory, never
// listed here. A skill is a folder in app/skills/: dropping one in is the whole of adding a
// capability, and this file never learns its name. Naming any skill is what adds the Skill tool.
//
// The skills carry the know-how (how a deliverable is built, and the boilerplate it is built
// from); the system prompt stays generic. That is the split — capability lives in skills, not in
// this client and not in a per-agent config.
const SKILLS = existsSync(SKILLS_DIR)
  ? readdirSync(SKILLS_DIR, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort()
  : [];

interface ManifestItems {
  type: string;
  enum?: string[];
}
interface ManifestParam {
  name: string;
  type: string;
  description: string;
  required: boolean;
  // Present only on array params (Ruby omits the key otherwise), so an absent
  // `items` means "not an array" — never "an array of something unknown".
  items?: ManifestItems;
}
interface ManifestTool {
  name: string;
  description: string;
  needs_approval: boolean;
  parameters: ManifestParam[];
}
interface Attachment {
  path: string;
  media_type: string;
  kind: "image" | "document" | "file";
}
interface Config {
  api_key: string;
  prompt: string;
  system_prompt: string;
  model: string;
  manifest: ManifestTool[];
  resume?: string | null;
  max_turns?: number | null;
  attachments?: Attachment[];
}

// The turn as a streaming user message: the text, plus a content block per inlinable upload
// (image/document, base64 read from the staged /uploads file). "file" kinds are staged-only and
// already named in the text's Read note. Streaming input is the ONLY query() mode that carries blocks.
async function* buildPrompt(config: Config): AsyncGenerator<SDKUserMessage> {
  const content: Array<Record<string, unknown>> = [
    { type: "text", text: config.prompt },
  ];
  for (const a of config.attachments ?? []) {
    if (a.kind === "image" || a.kind === "document") {
      content.push({
        type: a.kind,
        source: {
          type: "base64",
          media_type: a.media_type,
          data: readFileSync(a.path).toString("base64"),
        },
      });
    }
  }
  // The blocks are constructed from the Ruby manifest (runtime strings for kind/media_type); their
  // shape is the Anthropic API's own image/document base64 block, dogfood-proven. This is the typed
  // ↔ untyped boundary, so cast through unknown — the rest of the file stays type-checked.
  yield {
    type: "user",
    message: { role: "user", content },
    parent_tool_use_id: null,
  } as unknown as SDKUserMessage;
}

function emit(obj: unknown): void {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

// ── stdin: the tool_response channel ────────────────────────────────────────
// Ruby writes one line per pending tool call, keyed by id:
//   { type:"tool_response", id, result, is_error }        answers a tool_request
// It resolves the promise this client parked for that call. There is no approval channel:
// approvals never come back to a running process — the gate ends the run.
const pending = new Map<
  string,
  (r: { result: unknown; is_error: boolean }) => void
>();
let stdinBuf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk: string) => {
  stdinBuf += chunk;
  let nl: number;
  while ((nl = stdinBuf.indexOf("\n")) >= 0) {
    const line = stdinBuf.slice(0, nl).trim();
    stdinBuf = stdinBuf.slice(nl + 1);
    if (!line) continue;
    const msg = JSON.parse(line) as {
      type: string;
      id: string;
      result: unknown;
      is_error: boolean;
    };
    if (msg.type === "tool_response") {
      pending.get(msg.id)?.({ result: msg.result, is_error: msg.is_error });
      pending.delete(msg.id);
    }
  }
});

// ids of built-in tool_use blocks we emitted. Their results are ours to log; our MCP tools' are
// not — the Ruby bridge already logs those.
const builtinUseIds = new Set<string>();

let toolSeq = 0;
function callRuby(
  name: string,
  args: Record<string, unknown>,
): Promise<{ result: unknown; is_error: boolean }> {
  const id = `t${++toolSeq}`;
  return new Promise((resolve) => {
    pending.set(id, resolve);
    emit({ type: "tool_request", id, name, args });
  });
}

// An array param's ITEM type. A closed `enum` is the whole point of declaring it: the
// model sees the seven legal values of by_objectif instead of inventing one.
function zodItem(items: ManifestItems): z.ZodTypeAny {
  if (items.enum?.length) return z.enum(items.enum as [string, ...string[]]);
  switch (items.type) {
    case "integer":
    case "number":
      return z.number();
    case "boolean":
      return z.boolean();
    default:
      return z.string();
  }
}

// A manifest param → a Zod type. Non-scalar types MUST be modeled faithfully: an "array"
// declared as a string makes the model guess CSV/space/JSON formats (and tools then mis-parse
// the single blob). Ruby declares the item type, so nothing here guesses it.
function zodType(p: ManifestParam): z.ZodTypeAny {
  switch (p.type) {
    case "integer":
    case "number":
      return z.number();
    case "boolean":
      return z.boolean();
    case "array":
      return z.array(p.items ? zodItem(p.items) : z.string());
    case "object":
      return z.record(z.string(), z.unknown());
    default:
      return z.string();
  }
}

// A manifest param list → a Zod raw shape (what tool() wants for its inputSchema).
function zodShape(params: ManifestParam[]): Record<string, z.ZodTypeAny> {
  const shape: Record<string, z.ZodTypeAny> = {};
  for (const p of params) {
    let t = zodType(p);
    if (p.description) t = t.describe(p.description);
    if (!p.required) t = t.optional();
    shape[p.name] = t;
  }
  return shape;
}

async function main(): Promise<void> {
  const config = JSON.parse(readFileSync(process.argv[2], "utf8")) as Config;

  // TWO kinds of credential, TWO variables — they are not interchangeable.
  //
  //   sk-ant-api03… → an API key    → ANTHROPIC_API_KEY      (billed to the API account)
  //   sk-ant-oat01… → an OAuth token → CLAUDE_CODE_OAUTH_TOKEN (billed to a Claude subscription)
  //
  // Handing an OAuth token to ANTHROPIC_API_KEY does not degrade — the CLI rejects it outright
  // with "Invalid API key · Fix external API key", which is it telling us we passed an external
  // key that is not one. The prefix IS the discriminator, so read it rather than making the caller
  // declare which kind it holds: credentials hold one token, and it knows what it is.
  const token = config.api_key;
  if (token?.startsWith("sk-ant-oat")) {
    process.env.CLAUDE_CODE_OAUTH_TOKEN = token;
  } else {
    process.env.ANTHROPIC_API_KEY = token;
  }

  const needsApproval = new Set(
    config.manifest.filter((m) => m.needs_approval).map((m) => m.name),
  );
  const ourTools = new Set(config.manifest.map((m) => m.name));

  // Every manifest tool → an in-process MCP tool whose handler round-trips to Ruby over stdio.
  const tools = config.manifest.map((m) =>
    tool(
      m.name,
      m.description,
      zodShape(m.parameters),
      async (args: Record<string, unknown>) => {
        const { result, is_error } = await callRuby(m.name, args);
        return {
          content: [{ type: "text", text: JSON.stringify(result) }],
          isError: is_error,
        };
      },
    ),
  );

  const server = createSdkMcpServer({ name: SERVER, version: "1.0.0", tools });

  // The built-ins the agent may reach. Bash is one of them now.
  //
  // It was not, and could not be, while this ran on the developer's machine: there is no
  // scoped-ALLOW syntax for Bash (only scoped deny), so a shell could not be path-gated, and the
  // rules that tried were the rules nobody could read — `bun install --cwd 56` denied while
  // `ls`, sanctioned nowhere, ran. The build became a tool to escape that.
  //
  // The turn now runs in a disposable box that holds one conversation's work and nothing else: no
  // repo, no /Users/ben, no other tenant. There is nothing there to path-gate. The container is
  // the boundary; canUseTool never was a good filesystem guard and no longer pretends to be one.
  const BUILTIN = new Set(["Read", "Write", "Edit", "Glob", "Grep", "Bash"]);

  // ONLY our MCP tools. Nothing else goes in here.
  //
  // A bare entry ("Read", "Bash") auto-approves that tool GLOBALLY, before canUseTool and before
  // any path rule — so listing Read/Edit lets the agent read anywhere on the disk, and listing
  // Bash(...) allowlists Bash WHOLESALE (there is no scoped-allow syntax for Bash; only scoped
  // DENY). That is how `find /Users/ben/...` ran against an explicit deny branch.
  //
  // The file tools and the two bun commands are granted by the workspace's own settings.json,
  // which the Runner writes — path-scoped to ./**, which is the chat's workspace and nothing else.
  const allowedTools = config.manifest
    .filter((m) => !m.needs_approval)
    .map((m) => `mcp__${SERVER}__${m.name}`);

  // The tools that EXIST for this agent. Without this the SDK exposes its whole built-in surface,
  // and two of them break us outright:
  //
  //   Agent/Task — the agent delegates work to a subagent, which runs in ITS OWN context with no
  //     access to our stdio bridge. It can Read/Write/Bash, so the work SUCCEEDS, and then every
  //     mcp__rbrun__* call returns "Stream closed" — the tool result can never cross the bridge back,
  //     so the work lands on disk but nothing is ever persisted through the runner.
  //   ScheduleWakeup — the agent schedules itself to poll subagents it should not have spawned.
  //
  // Trimming also keeps us under the SDK's tool-schema deferral: past some count it ships names
  // without schemas and the model must ToolSearch first, calling tools blind meanwhile (that is the
  // `enum_options: received undefined` we saw). 37 MCP tools + ~29 built-ins was far over; this is
  // 37 + 7.
  const TOOLS = ["Skill", "Read", "Write", "Edit", "Glob", "Grep", "Bash"];

  let sessionEmitted = false;
  let sessionId: string | null = null;
  const captureSession = (id?: string) => {
    if (!id) return;
    sessionId = id;
    if (!sessionEmitted) {
      sessionEmitted = true;
      emit({ type: "session", session_id: id });
    }
  };

  // Set the moment we gate a call. `interrupt: true` tears the run down, and the SDK surfaces
  // that teardown as a throw — which is CORRECT behaviour we asked for, not a failure. This flag
  // is how we tell "the owner must decide" apart from a real crash, so the run ends clean instead
  // of reaching Rails as "erreur technique" (the original bug that made us hold the process open).
  let gated = false;
  let resultEmitted = false;

  const response = query({
    prompt: buildPrompt(config),
    options: {
      systemPrompt: config.system_prompt,
      model: config.model,
      // A tool-heavy agent (build audience → fetch roster → draft) needs headroom to REACH its
      // final structured emit; the SDK default cap cuts the turn off mid-work, yielding a
      // null structured_output. Generous by default, overridable per run.
      maxTurns: config.max_turns ?? 60,
      mcpServers: { [SERVER]: server },
      tools: TOOLS, // what EXISTS — see the const. Without it the SDK ships its whole surface.
      allowedTools,
      // Load project settings FROM CWD — the chat's workspace — so the skills the runner staged
      // into <workspace>/.claude/skills/ are discovered. This is "project", not "user": the SDK
      // would read a co-located .claude as *user* source if HOME were the cwd, which is why the
      // runner sets CLAUDE_CONFIG_DIR instead of HOME. Nothing of the developer's own ~/.claude
      // (plugins, commands, foreign skills) can reach the agent.
      settingSources: ["project"],
      skills: SKILLS, // teaches it how an artifact is built (auto-adds the Skill tool)
      includePartialMessages: true,
      ...(config.resume ? { resume: config.resume } : {}),
      canUseTool: async (
        toolName: string,
        input: Record<string, unknown>,
        opts: { toolUseID: string },
      ) => {
        // The built-ins are allowed outright: cwd is this chat's box, and the box is the boundary.
        if (BUILTIN.has(toolName))
          return { behavior: "allow", updatedInput: input };
        const bare = toolName.replace(`mcp__${SERVER}__`, "");
        if (!ourTools.has(bare)) {
          return {
            behavior: "deny",
            message: `Tool ${toolName} is not available. Use only your dedicated tools.`,
          };
        }
        if (needsApproval.has(bare)) {
          // The gate ENDS the run. Emit the pending call — its name and args are frozen here and
          // become the durable row Rails renders and, on approval, executes verbatim — then deny
          // with `interrupt: true` so the SDK tears the turn down and we exit. Nothing waits: no
          // held promise, no timeout, no process pinned to a human. The conversation continues
          // later by resuming this session id.
          gated = true;
          emit({
            type: "needs_approval",
            tool: bare,
            arguments: input,
            tool_use_id: opts.toolUseID,
          });
          return {
            behavior: "deny",
            message: "Awaiting user approval.",
            interrupt: true,
          };
        }
        return { behavior: "allow", updatedInput: input };
      },
    },
  });

  try {
    await drain(response, captureSession, () => {
      resultEmitted = true;
    });
  } catch (err) {
    // A gated run ends by OUR interrupt: report it as a clean outcome, not a crash. Anything
    // else is a real error and stays one.
    if (!gated) throw err;
  }

  // The gate is a normal end of run. Rails reads stop_reason to flip the chat to needs_approval;
  // the frozen call is already on its way as the `needs_approval` line.
  if (gated && !resultEmitted) {
    emit({
      type: "result",
      session_id: sessionId,
      subtype: "awaiting_approval",
      errors: null,
      stop_reason: "awaiting_approval",
      structured_output: null,
    });
  }
  process.exit(0);
}

// The SDK message stream → our JSONL protocol.
async function drain(
  response: AsyncIterable<unknown>,
  captureSession: (id?: string) => void,
  onResult: () => void,
): Promise<void> {
  for await (const message of response) {
    const m = message as {
      type: string;
      session_id?: string;
      event?: { type?: string; delta?: { type?: string; text?: string } };
      message?: {
        content?: Array<{
          type?: string;
          text?: string;
          id?: string;
          name?: string;
          input?: unknown;
          tool_use_id?: string;
          content?: unknown;
          is_error?: boolean;
        }>;
      };
      structured_output?: unknown;
    };
    captureSession(m.session_id);

    if (
      m.type === "stream_event" &&
      m.event?.type === "content_block_delta" &&
      m.event.delta?.type === "text_delta"
    ) {
      emit({ type: "token", text: m.event.delta.text ?? "" });
    }
    if (m.type === "assistant") {
      const text = (m.message?.content ?? [])
        .filter((b) => b.type === "text")
        .map((b) => b.text ?? "")
        .join("");
      if (text) emit({ type: "assistant", text });

      // Built-in tools (Skill, Read, Write, Edit, Glob, Grep, Bash) run INSIDE the SDK — they
      // never reach the stdio bridge, so without this Ruby sees nothing while the agent reads the
      // skill, writes its data, and compiles: the conversation shows one long silence and the
      // spinner is the only sign of life. The blocks are already in this stream; emit them.
      //
      // Our OWN tools are excluded: the bridge logs those in Ruby (AgentTurn#run_tool), so
      // emitting them here too would write every row twice.
      for (const block of m.message?.content ?? []) {
        if (
          block.type === "tool_use" &&
          block.id &&
          block.name &&
          !block.name.startsWith(`mcp__${SERVER}__`)
        ) {
          builtinUseIds.add(block.id);
          emit({
            type: "builtin_tool_use",
            id: block.id,
            name: block.name,
            input: block.input ?? {},
          });
        }
      }
    }

    // A built-in's RESULT comes back as a user message carrying tool_result blocks — the other
    // half of the pair above, and what turns a card from running into done.
    //
    // ONLY for ids we emitted a builtin_tool_use for. The exclusion above was on the tool_use half
    // alone, so every one of OUR tools' results was logged twice — once by the Ruby bridge, once
    // here — and a GATED call got a phantom result carrying the SDK's own "user doesn't want to
    // proceed" text, against a tool_use_id that is meant to have no result at all. The frozen row
    // says pending and nothing ran; the log said otherwise.
    if (m.type === "user") {
      for (const block of m.message?.content ?? []) {
        if (
          block.type === "tool_result" &&
          block.tool_use_id &&
          builtinUseIds.has(block.tool_use_id)
        ) {
          emit({
            type: "builtin_tool_result",
            tool_use_id: block.tool_use_id,
            content: block.content ?? null,
            is_error: !!block.is_error,
          });
        }
      }
    }
    if (m.type === "result") {
      captureSession(m.session_id);
      onResult();
      const r = m as {
        subtype?: string;
        errors?: string[];
        stop_reason?: string | null;
      };
      emit({
        type: "result",
        session_id: m.session_id ?? null,
        subtype: r.subtype ?? null,
        errors: r.errors ?? null,
        stop_reason: r.stop_reason ?? null,
        structured_output: m.structured_output ?? null,
      });
    }
  }
}

main().catch((err: unknown) => {
  const e = err as Error;
  // process.exit() TRUNCATES the stdout buffer — emit()+exit dropped this line, so Rails only ever
  // saw a bare non-zero exit ("client exited non-zero") and the REAL error was lost on every failure
  // (notably every continue/resume). Write with a callback and exit only once it has flushed to the
  // pipe; carry the stack so the Rails log names the actual cause. Also echo to stderr (drained and
  // logged at debug) as a belt-and-braces copy.
  const detail = e?.stack || e?.message || String(err);
  // process.exit() truncates the stdout buffer, so emit()+exit dropped the message and Rails saw a
  // bare non-zero exit. Write with a callback and exit only once it has flushed to the pipe, so the
  // REAL error (with stack) reaches Rails on a thrown/exit-1 failure. (A SIGNAL kill never reaches
  // here — the Runner names that from the exit status.)
  try { process.stderr.write(`[client fatal] ${detail}\n`); } catch { /* pipe may be gone */ }
  process.stdout.write(
    JSON.stringify({ type: "error", message: detail }) + "\n",
    () => process.exit(1),
  );
});
