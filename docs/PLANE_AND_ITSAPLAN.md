# Management Tooling Guide: Plane.so & It's a Plan

This guide outlines setup, administration, and AI agent integration for both project management tools deployed on the cluster.

---

## 1. Plane (`plane.so`)

**Plane** is an enterprise-grade, extensible project management suite designed as an open-source alternative to Jira and Linear.

### Features:
- **Workspaces & Projects**: Organize work across multiple teams and initiatives.
- **Issues & Cycles**: Sprint planning, backlog management, and cycle analytics.
- **Modules**: Break complex goals down into sub-initiatives.
- **Pages**: Notion-style collaborative rich-text documentation directly inside projects.
- **Views**: Spreadsheet table view, Kanban boards, calendar, and Gantt timeline.

### First-Time Access:
1. Navigate to `https://plane.<yourdomain.com>`.
2. Complete the initial admin setup wizard to create your primary workspace.
3. Invite team members via email or workspace invite links.

---

## 2. It's a Plan (`itsaplan.dev`)

**It's a Plan** is a lightweight, AI-native project tracker built around the concept of **AI Agents as first-class team members**.

### Key Differentiators:
- **Human + AI Teammates**: Directly delegate issues to AI agents (Claude, GPT-4o, DeepSeek, or local Ollama models).
- **No Per-Seat Pricing**: Self-hosted and fully private with your own API keys.
- **MCP (Model Context Protocol)**: Exposes endpoints for CLI tools (like Claude Code or Antigravity) to query and update issues.
- **Zero Heavyweight Overhead**: High performance Next.js and Bun backend.

### Architecture in Kubernetes:
- **Web App**: Next.js frontend running on port 3001 (`itsaplan.<yourdomain.com>`).
- **API**: Bun backend running on port 3000 (`api.itsaplan.<yourdomain.com>`).
- **PostgreSQL 17**: Relational database with automated migrations.
- **RustFS / S3**: Fast local S3-compatible storage for attachments.
- **Worker**: Asynchronous webhook dispatcher and agent execution queue.
- **Bot**: Telegram bot runner for instant updates and conversational issue assignment.

### Setting Up AI Agent Keys:
1. Sign in to your It's a Plan instance.
2. Go to **Settings** -> **AI Providers**.
3. Add your provider API key (e.g. Anthropic, OpenAI, or local Ollama URL).
4. Keys are automatically encrypted with AES-256-GCM using `APP_ENCRYPTION_KEY`.
