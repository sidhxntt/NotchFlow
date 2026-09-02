# NotchFlow Landing Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a responsive, ElevenLabs-inspired marketing landing page for NotchFlow as a Vite application in `web/`.

**Architecture:** A single React composition page will render semantic marketing sections from small local components and data arrays. A token-driven CSS stylesheet will implement the imported ElevenLabs visual system—off-white editorial canvas, light serif display headings, ink pills, hairlines, and pastel atmospheric orbs—while real application screenshots are served from `web/public/product/`.

**Tech Stack:** Vite, React, plain CSS, existing JPEG product screenshots.

**Spec:** `DESIGN.md`

## Global Constraints

- Create the complete website inside `web/` using Vite and React.
- Use the ElevenLabs source in `DESIGN.md` heavily: canvas `#f5f5f5`, warm ink, editorial light serif, Inter body, pill CTAs, 16px cards, 96px section rhythm, and pastel atmospheric orbs.
- Use existing NotchFlow screenshots; do not claim unsupported product features or publish pricing that is not configured.
- Include product purpose, install CTA, core workspaces, agent approvals, local-first privacy, seven-day trial/perpetual license, FAQ, and responsive navigation.
- Keep the page usable without a backend: CTAs must use safe anchors and the mobile menu and FAQ must work locally.

---

### Task 1: Vite foundation and design system

**Files:**
- Create: `web/package.json`
- Create: `web/index.html`
- Create: `web/src/main.jsx`
- Create: `web/src/styles.css`
- Create: `web/public/product/` copied existing product JPEGs

**Interfaces:**
- Produces a `npm run build` Vite application and shared CSS variables consumed by page components.

- [x] **Step 1: Create the Vite React application in `web/`**

Run: `npm create vite@latest web -- --template react`

- [x] **Step 2: Install its dependencies**

Run: `npm install` from `web/`

- [x] **Step 3: Define the visual tokens and responsive base in `src/styles.css`**

```css
:root {
  --canvas: #f5f5f5;
  --ink: #0c0a09;
  --body: #4e4e4e;
  --hairline: #e7e5e4;
  --surface: #ffffff;
  --mint: #a7e5d3;
  --peach: #f4c5a8;
  --lavender: #c8b8e0;
}
```

- [x] **Step 4: Copy the actual NotchFlow product screenshots into the Vite public folder**

Run: `cp .github/shots/{verb-ask,agent-answer,agent-compose,power-search}.jpg web/public/product/`

- [x] **Step 5: Build the styled application**

Run: `npm run build`

Expected: Vite completes with no errors.

### Task 2: Compose the full NotchFlow landing page

**Files:**
- Create: `web/src/App.jsx`
- Modify: `web/src/main.jsx`
- Modify: `web/src/styles.css`

**Interfaces:**
- Consumes the Vite application and product image paths from Task 1.
- Produces an accessible one-page marketing surface with `#product`, `#agents`, `#privacy`, `#license`, and `#faq` anchors.

- [x] **Step 1: Write a smoke test checklist before implementation**

Checklist: navigation opens on mobile, FAQ answers toggle, “See the flow” scrolls to product, and product screenshots load from `/product/`.

- [x] **Step 2: Create focused React components**

```jsx
function Header() { /* brand, desktop links, mobile menu */ }
function Hero() { /* primary product promise and CTA */ }
function ProductPreview() { /* screenshot-led live product demonstration */ }
function FeatureGrid() { /* Ask, Notes, Reminders, Agent workspaces */ }
function AgentSection() { /* Codex/Claude approval flow */ }
function TrustSection() { /* local-first privacy and licensing */ }
function FAQ() { /* keyboard-accessible disclosure controls */ }
function Footer() { /* product, legal, GitHub links */ }
```

- [x] **Step 3: Implement the hero and screenshot-led product demo**

Use the actual `verb-ask.jpg` as the center product image, with a prominent but restrained “Download for macOS” primary CTA and a “See the flow” secondary CTA.

- [x] **Step 4: Implement product, agent, privacy, licensing, FAQ, and footer sections**

Use only accurate README/PRD claims: macOS 14+, Apple silicon, a hardware notch is optional, supported local Codex/Claude work, seven-day trial, and perpetual paid license.

- [x] **Step 5: Implement small interactions and accessibility behavior**

Use real `button` controls with `aria-expanded` for the mobile menu and FAQ, preserve visible keyboard focus, and honor `prefers-reduced-motion`.

- [x] **Step 6: Build the complete page**

Run: `npm run build`

Expected: Vite completes with no errors.

### Task 3: Visual QA and responsive verification

**Files:**
- Modify: `web/src/App.jsx` and `web/src/styles.css` only if QA identifies visible drift.

**Interfaces:**
- Consumes the complete built page.
- Produces a verified desktop and mobile landing page.

- [x] **Step 1: Start Vite and inspect in a browser**

Run: `npm run dev -- --host 127.0.0.1`

- [x] **Step 2: Verify primary interactions**

Test desktop anchors, mobile navigation, FAQ disclosure, and both hero CTAs.

- [x] **Step 3: Compare the page to `DESIGN.md` at desktop and mobile widths**

Check: off-white canvas, editorial serif heading scale, Inter UI text, black pill CTA, pastel orbs, thin card borders, 96px section rhythm, image framing, and no horizontal overflow.

- [x] **Step 4: Run production build after any QA fixes**

Run: `npm run build`

Expected: Vite completes with no errors.
