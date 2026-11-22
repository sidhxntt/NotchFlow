import { useEffect, useState } from 'react'
import './App.css'

const baseAsset = (path) => `${import.meta.env.BASE_URL}${path}`
// Absolute, from the site's base path: a relative `privacy/` stacked up
// (/privacy/privacy/…) whenever the page was opened at a nested URL.
const privacyHref = baseAsset('privacy/')
const REPO = 'https://github.com/sidhxntt/notchflow'
const RELEASES = `${REPO}/releases/latest`
const navItems = [['Features', '#features'], ['Agents', '#agents'], ['Install', '#install'], ['FAQ', '#faq']]

const faqs = [
  ['Does NotchFlow need a hardware notch?', 'No. On Macs without a notch and on external displays, NotchFlow draws a virtual notch and works the same way.'],
  ['Do I need an account or an API key?', 'There is no NotchFlow account. Add a provider API key, use a supported sign-in, or connect a CLI you already use, such as Codex or Claude Code. Notes, reminders, the File tray and media need no key at all.'],
  ['What happens after the seven-day trial?', 'NotchFlow asks for a license key before it opens the notch again. Your notes, history, files and settings stay on your Mac. A license is a one-time purchase and includes future updates.'],
  ['Where does my data go?', 'Your prompts, history, files, notes and agent records stay on your Mac. Requests go straight to the provider, CLI or search service you choose. NotchFlow has no server in between.'],
  ['Can I use local models?', 'Yes. Add any OpenAI-compatible endpoint in Settings: Ollama, LM Studio, vLLM, your own gateway, or a provider NotchFlow does not list. A key is optional for custom endpoints.'],
  ['What do file conversions need?', 'The free Media Automations CLI (npm i -g my_media_automations). NotchFlow finds it on its own; without it, the convert menu stays hidden.'],
  ['Which agents show up in the Agent tab?', 'Codex and Claude Code sessions on your Mac appear on their own, including ones you started in Terminal. Tasks you start from the notch can also run on Grok, Command Code or PI.'],
  ['Will an agent ever act without me?', 'No. When an agent asks permission, you choose Approve or Deny in the notch. If NotchFlow is closed, the agent asks in its own terminal as usual.'],
  ['What is the difference between Generic and Agentic mode?', 'Generic mode has media, files, notes, reminders and the utilities. Agentic mode adds chat, agent tasks, approvals and AI activity. Switching keeps everything you saved.'],
  ['Why does NotchFlow ask for permissions?', 'Only when a feature needs one: Automation for Apple Notes and Reminders, Calendar for your events, notifications for alerts. Settings → General shows each one, and Notes can save to Markdown files instead.'],
  ['Is it on the Mac App Store?', 'No. NotchFlow is a direct download: a Developer ID-signed, Apple-notarized DMG, with a ZIP as a fallback. It updates itself.'],
  ['How do I uninstall it?', 'Drag NotchFlow.app from Applications to the Trash.'],
]

function Arrow() { return <svg aria-hidden="true" className="arrow" viewBox="0 0 20 20" fill="none"><path d="M3.5 10h12M11 5.5 15.5 10 11 14.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" /></svg> }
function Mark() { return <img className="brand-mark" src={baseAsset('icon.png')} alt="" /> }

// The release asset carries its version in its name, so the newest DMG is
// looked up once; until then (or if GitHub is unreachable) links go to the
// release page.
let dmgLookup
function useLatestDmg() {
  const [href, setHref] = useState(RELEASES)
  useEffect(() => {
    dmgLookup ??= fetch('https://api.github.com/repos/sidhxntt/notchflow/releases/latest')
      .then((r) => (r.ok ? r.json() : null))
      .then((release) => release?.assets?.find((a) => a.name.endsWith('.dmg'))?.browser_download_url ?? RELEASES)
      .catch(() => RELEASES)
    let live = true
    dmgLookup.then((url) => { if (live) setHref(url) })
    return () => { live = false }
  }, [])
  return href
}

// On a phone there is nothing to install, so the download becomes a way to
// get the link onto the Mac: the share sheet, or the clipboard.
function SendLinkButton({ className = '' }) {
  const [state, setState] = useState('idle')
  const send = async () => {
    const url = window.location.href.split('#')[0]
    try {
      if (navigator.share) await navigator.share({ title: 'NotchFlow for macOS', url })
      else { await navigator.clipboard.writeText(url); setState('copied') }
    } catch { /* share sheet dismissed */ }
  }
  return <button type="button" className={`button only-narrow ${className}`} onClick={send}>{state === 'copied' ? 'Link copied' : 'Send the link to your Mac'}</button>
}

function DownloadButton({ label = 'Download for macOS', className = '' }) {
  const href = useLatestDmg()
  return <>
    <a className={`button only-wide ${className}`} href={href}>{label} <Arrow /></a>
    <SendLinkButton className={className} />
  </>
}

// Arrow keys move between tabs, as in any native tab bar.
function onTabKey(event, index, count, select) {
  const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key]
  if (!step) return
  event.preventDefault()
  const next = (index + step + count) % count
  select(next)
  event.currentTarget.parentElement.children[next]?.focus()
}

function Header() {
  const [open, setOpen] = useState(false)
  const close = () => setOpen(false)
  useEffect(() => {
    if (!open) return undefined
    const onKey = (e) => { if (e.key === 'Escape') close() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open])
  return <header className="site-header">
    <a className="brand" href="#top" onClick={close} aria-label="NotchFlow home"><Mark /><span>NotchFlow</span></a>
    <nav className="nav-links" aria-label="Primary navigation">{navItems.map(([label, href]) => <a key={href} href={href}>{label}</a>)}</nav>
    <div className="nav-actions"><a className="text-link" href={REPO} target="_blank" rel="noreferrer">GitHub</a><DownloadButton label="Download" className="button--small" /></div>
    <button className="menu-button" type="button" aria-expanded={open} aria-controls="mobile-menu" onClick={() => setOpen(!open)}><span /><span /><span className="sr-only">{open ? 'Close navigation' : 'Open navigation'}</span></button>
    <div id="mobile-menu" className={`mobile-menu ${open ? 'mobile-menu--open' : ''}`}>{navItems.map(([label, href]) => <a key={href} href={href} onClick={close}>{label}</a>)}<a href={REPO} target="_blank" rel="noreferrer" onClick={close}>GitHub <Arrow /></a></div>
  </header>
}

const heroScenes = [
  { tab: 'Ask', prompt: '18% tip on 284.60 split 3 ways', answer: 'Tip 51.23, total 335.83. That’s 111.94 each.', input: 'Ask anything' },
  { tab: 'Note', prompt: 'Idea: a weekly digest of agent runs', answer: 'Saved to Apple Notes. Open it any time from your history.', input: 'Save a thought' },
  { tab: 'Remind', prompt: 'Call the dentist tomorrow at 10', answer: 'Added to Apple Reminders · Tomorrow, 10:00 AM.', input: 'Set a reminder' },
  { tab: 'Agent', prompt: 'Fix the flaky login test', answer: 'Codex is working in ~/code/app. Close the notch; it keeps going.', input: 'Describe a task' },
]

const reducedMotion = () => typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches

function Hero() {
  const [scene, setScene] = useState(0)
  const [paused, setPaused] = useState(false)
  useEffect(() => {
    if (paused || reducedMotion()) return undefined
    const timer = setInterval(() => setScene((s) => (s + 1) % heroScenes.length), 4200)
    return () => clearInterval(timer)
  }, [paused])
  const current = heroScenes[scene]
  const pick = (index) => { setScene(index); setPaused(true) }
  return <section className="hero" id="top">
    <div className="orb orb--hero-a" /><div className="orb orb--hero-b" /><div className="orb orb--hero-c" />
    <div className="hero-copy">
      <h1>Type into your notch.</h1>
      <p className="hero-text">NotchFlow answers, saves a note, sets a reminder or hands the job to Codex or Claude Code, from the notch at the top of your screen. It also keeps your files, music and agent sessions one hover away.</p>
      <div className="hero-actions"><DownloadButton /><a className="button button--outline" href="#features">See what it does <Arrow /></a></div>
      <p className="hero-meta">7-day free trial · macOS 14+ · Apple silicon</p>
    </div>
    <div className="hero-stage" aria-label="NotchFlow app preview" onMouseEnter={() => setPaused(true)}>
      <div className="notch-shell">
        <div className="notch-bar"><span /><span /><span /></div><div className="notch-glow" />
        <div className="notch-content">
          <div className="demo-tabs" role="tablist" aria-label="Preview a destination">{heroScenes.map((s, index) => <button type="button" role="tab" id={`hero-tab-${index}`} aria-controls="hero-panel" aria-selected={index === scene} tabIndex={index === scene ? 0 : -1} key={s.tab} className={`demo-tab ${index === scene ? 'demo-tab--active' : ''}`} onClick={() => pick(index)} onKeyDown={(e) => onTabKey(e, index, heroScenes.length, pick)}>{s.tab}</button>)}</div>
          <div className="demo-swap" key={scene} id="hero-panel" role="tabpanel" aria-labelledby={`hero-tab-${scene}`}><p className="demo-prompt">{current.prompt}</p><div className="demo-answer"><span className="answer-dot" /><p>{current.answer}</p></div></div>
          <div className="demo-input"><span>{current.input}</span><b>↵</b></div>
        </div>
      </div>
      <p className="stage-caption">Pick a tab to see where each kind of line goes.</p>
    </div>
  </section>
}

// ——— Main features ———

function Icon({ d, className = 'mock-icon' }) {
  return <svg className={className} aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">{d}</svg>
}
const icons = {
  wand: <><path d="m4 20 10-10M14 4v3M19 9h3M17.5 5.5l2-2M16 12l2 2" /></>,
  eye: <><path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z" /><circle cx="12" cy="12" r="2.6" /></>,
  share: <><path d="M12 15V3.5M8 7.5l4-4 4 4" /><path d="M6 11H5v9h14v-9h-1" /></>,
  x: <><path d="M6 6l12 12M18 6 6 18" /></>,
  play: <><path d="M8 5.5v13l10.5-6.5L8 5.5Z" fill="currentColor" stroke="none" /></>,
  pause: <><path d="M8 5h3v14H8zM13 5h3v14h-3z" fill="currentColor" stroke="none" /></>,
  next: <><path d="M5 6v12l8-6-8-6ZM13 6v12l8-6-8-6Z" fill="currentColor" stroke="none" /></>,
  prev: <><path d="M19 6v12l-8-6 8-6ZM11 6v12l-8-6 8-6Z" fill="currentColor" stroke="none" /></>,
}

const trayFiles = [
  { name: 'launch-hero.heic', ext: 'HEIC', selected: true },
  { name: 'launch-detail.heic', ext: 'HEIC', selected: true },
  { name: 'pricing-2026.csv', ext: 'CSV' },
  { name: 'release-notes.md', ext: 'MD' },
]

function TrayMock() {
  return <div className="mock-panel" role="img" aria-label="The File tray with two HEIC photos selected and the convert menu open, offering PNG, JPEG, WebP, compression and background removal">
    <div className="mock-head"><span>File tray</span><span className="mock-actions"><Icon d={icons.wand} /><Icon d={icons.eye} /><Icon d={icons.share} /><Icon d={icons.x} /></span></div>
    <div className="tray-rows">{trayFiles.map((f) => <div className={`tray-row ${f.selected ? 'tray-row--on' : ''}`} key={f.name}><span className="tray-thumb">{f.ext}</span><span className="tray-name">{f.name}<small>{f.ext}</small></span></div>)}</div>
    <div className="tray-menu">
      <span className="tray-menu-title">2 files</span>
      <span className="tray-menu-group">Convert to</span><span>PNG</span><span>JPEG</span><span>WebP</span>
      <span className="tray-menu-group">Compress</span><span>Normal · Super · Ultra</span>
      <span className="tray-menu-group">Background</span><span>Remove background</span>
    </div>
    <div className="mock-keys"><kbd>⇧ ↑↓</kbd> select <kbd>Space</kbd> Quick Look <kbd>⌘⌫</kbd> remove</div>
  </div>
}

// The Chat and notes demo: each pill types an example into a mock notch and
// shows where it would go. Your own text is sorted by a small keyword guess
// that stands in for the app's on-device model.
const intentLabels = { ask: 'Ask', note: 'Note', remind: 'Remind', agent: 'Agent' }
const intentOutcomes = {
  ask: 'Sent to the model you chose. The answer streams in right here.',
  note: 'Saved to Apple Notes, or to a Markdown file if you prefer.',
  remind: 'Added to Apple Reminders, with the time you wrote.',
  agent: 'Ready for Codex, Claude Code or another agent, in the project folder you pick.',
}
const chatExamples = [
  { label: 'Ask', text: 'What’s the difference between a mutex and a semaphore?', intent: 'ask', result: 'A mutex lets one thread in at a time; a semaphore lets in up to N.' },
  { label: 'Web search', text: 'What’s new in the latest macOS release?', intent: 'ask', result: 'Searched the web with your own key, then answered with the source cited.' },
  { label: 'Exact math', text: '18% tip on 284.60 split 3 ways', intent: 'ask', result: 'Tip 51.23, total 335.83 — 111.94 each.' },
  { label: 'Note', text: 'The spare key is in the blue box by the door', intent: 'note', result: 'Saved to Apple Notes.' },
  { label: 'Reminder', text: 'Remind me to send the invoice Friday at 4pm', intent: 'remind', result: 'Reminder set · Friday, 4:00 PM.' },
]

function guessIntent(raw) {
  const t = raw.trim().toLowerCase()
  if (!t) return null
  if (/^(fix|refactor|implement|add|build|write|migrate|rename|create|debug|port|upgrade|bump)\b/.test(t)
      && /\b(test|tests|file|files|component|view|api|bug|function|repo|code|endpoint|module|ci|build|page|types?)\b/.test(t)) return 'agent'
  if (/\bremind me\b|\b(tomorrow|tonight|today at|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next week)\b|\bat \d{1,2}(:\d{2})?\s?(am|pm)\b/.test(t)) return 'remind'
  if (/\?$/.test(t) || /^(what|why|how|who|when|where|which|is|are|can|could|should|does|do|explain|summari[sz]e|translate|define)\b/.test(t)
      || /\d\s*(%|x|\*|\+|-|\/)\s*\d|\bsplit\b/.test(t)) return 'ask'
  return 'note'
}

function ChatDemo() {
  const [selected, setSelected] = useState(0)
  const [chars, setChars] = useState(0)
  const [custom, setCustom] = useState('')
  const example = chatExamples[selected]
  const usingCustom = custom.trim().length > 0
  const typed = reducedMotion() ? example.text : example.text.slice(0, chars)
  const text = usingCustom ? custom : typed
  const done = usingCustom || typed === example.text
  const intent = usingCustom ? guessIntent(custom) : (done ? example.intent : null)
  const result = usingCustom ? (intent ? intentOutcomes[intent] : '') : example.result
  const choose = (index) => { setCustom(''); setSelected(index); setChars(0) }

  useEffect(() => {
    if (usingCustom || reducedMotion()) return undefined
    const timer = setInterval(() => setChars((c) => (c >= example.text.length ? c : c + 1)), 32)
    return () => clearInterval(timer)
  }, [selected, usingCustom, example.text])

  return <div className="chat-demo">
    <div className="gallery-tabs" role="tablist" aria-label="Chat and notes examples">{chatExamples.map((item, index) => <button type="button" role="tab" aria-selected={!usingCustom && index === selected} tabIndex={index === selected ? 0 : -1} key={item.label} className={`gallery-tab ${!usingCustom && index === selected ? 'gallery-tab--active' : ''}`} onClick={() => choose(index)} onKeyDown={(e) => onTabKey(e, index, chatExamples.length, choose)}>{item.label}</button>)}</div>
    <div className="notch-shell chat-demo-shell" aria-live="polite">
      <div className="notch-bar"><span /><span /><span /></div><div className="notch-glow" />
      <div className="notch-content">
        <div className="demo-tabs">{Object.entries(intentLabels).map(([key, label]) => <span key={key} className={`demo-tab ${intent === key ? 'demo-tab--active' : ''}`}>{label}</span>)}</div>
        <p className="demo-prompt demo-prompt--typed">{text}<i className="demo-caret" /></p>
        <div className={`demo-answer demo-result ${done && result ? 'demo-result--shown' : ''}`}><span className="answer-dot" /><p>{done ? result : ''}</p></div>
        <div className="demo-input"><span>{intent ? `Sends to ${intentLabels[intent]}` : 'Type to see the destination'}</span><b>↵</b></div>
      </div>
    </div>
    <label className="chat-demo-label" htmlFor="intent-try">Or type your own</label>
    <input id="intent-try" className="demo-field" value={custom} placeholder="e.g. Book flights to Goa next week" onChange={(e) => setCustom(e.target.value)} />
    <p className="demo-note">This page uses a simple keyword guess. In the app, NotchFlow reads each line on your Mac with an on-device language model, and you can change the destination before you press Return.</p>
  </div>
}

const usageProjects = [
  { name: 'landing-page', provider: 'Claude', sessions: '2 sessions', on: true },
  { name: 'api', provider: 'Codex', sessions: '1 session' },
  { name: 'notes', provider: 'Chat', sessions: '3 sessions' },
]
const cpuPoints = [30, 34, 28, 41, 52, 47, 38, 44, 61, 55, 42, 36, 39, 48, 57, 50, 43, 37, 33, 40]

function ActivityMock() {
  const line = cpuPoints.map((v, i) => `${(i / (cpuPoints.length - 1)) * 100},${40 - (v / 100) * 40}`).join(' ')
  return <div className="mock-pair" role="img" aria-label="The AI activity tab showing token usage per project and context use, beside Activity Monitor's CPU chart and memory figures">
    <div className="mock-panel">
      <div className="mock-head"><span>AI activity</span></div>
      {usageProjects.map((p) => <div className={`usage-row ${p.on ? 'usage-row--on' : ''}`} key={p.name}><span>{p.name}<small>{p.provider}</small></span><small>{p.sessions}</small></div>)}
      <div className="usage-detail">
        <div className="mock-stat"><span>Context</span><b>312k / 1M · 31%</b></div>
        <div className="mock-stat"><span>Last 5 hours</span><b>1.8M tokens</b></div>
        <div className="mock-stat"><span>Last 7 days</span><b>24.6M tokens</b></div>
      </div>
    </div>
    <div className="mock-panel">
      <div className="mock-head"><span>CPU</span><span className="mock-muted">Activity Monitor</span></div>
      <svg className="cpu-chart" viewBox="0 0 100 40" preserveAspectRatio="none" aria-hidden="true"><polyline points={`0,40 ${line} 100,40`} className="cpu-area" /><polyline points={line} className="cpu-line" /></svg>
      <div className="mock-stat"><span>System</span><b>12%</b></div>
      <div className="mock-stat"><span>User</span><b>31%</b></div>
      <div className="mock-stat"><span>Memory pressure</span><b>Normal</b></div>
      <div className="mock-stat"><span>Swap</span><b>0 MB</b></div>
    </div>
  </div>
}

function NowPlayingMock() {
  return <div className="mock-panel np" role="img" aria-label="Now Playing in the notch: artwork, track title, the source app, a progress bar and playback controls">
    <div className="np-art" aria-hidden="true" />
    <div className="np-body">
      <span className="np-source">Apple TV</span>
      <b className="np-title">Episode 4: The Long Way Home</b>
      <span className="np-artist">Season 2</span>
      <div className="np-bar"><span style={{ width: '38%' }} /></div>
      <div className="np-times"><span>18:42</span><span>-30:11</span></div>
      <div className="np-controls"><Icon d={icons.prev} /><Icon d={icons.pause} className="mock-icon np-main" /><Icon d={icons.next} /></div>
    </div>
  </div>
}

const showcase = [
  {
    id: 'file-tray', title: 'File tray', visual: <TrayMock />,
    text: 'Drop files, folders, links or text on the notch and they stay there until you need them. Shift-click or Shift and the arrow keys select several, Space opens Quick Look, and dragging one selected file takes the whole selection with it. Dropping into Finder copies, so your originals stay where they were.',
    sub: { title: 'Convert without opening another app', text: 'Select files of one type and convert them together: HEIC, PNG and other images to PNG, JPEG, WebP or SVG; video to GIF or MP3; CSV, JSON, YAML and Excel into each other; Markdown, Word and HTML to PDF. Compress images and video, or remove a photo’s background. Conversions run on your Mac through the free Media Automations CLI.' },
  },
  {
    id: 'chat', title: 'Chat and notes', visual: <ChatDemo />,
    text: 'Ask a question and the answer streams in under the prompt, with follow-ups in the same thread. It can search the web with your own key, calculate exactly, and read a chart or screenshot you copied. A line that reads like a note goes to Apple Notes or a Markdown file; one with a time becomes an Apple Reminder.',
  },
  {
    id: 'activity', title: 'AI activity and Activity Monitor', visual: <ActivityMock />,
    text: 'The AI tab adds up the tokens your Codex, Claude Code and chat sessions reported, per project, over the last 5 hours and 7 days, and shows how full each session’s context window is. Activity Monitor shows live CPU and memory pressure with the numbers underneath, and opens the full app in one click.',
  },
  {
    id: 'now-playing', title: 'Now Playing', visual: <NowPlayingMock />,
    text: 'Whatever macOS lists in Now Playing shows up in the notch: Apple Music, Spotify, Apple TV, YouTube Music or a browser tab. You get the artwork, play and pause, skip, and seeking where the app allows it.',
  },
]

function Features() {
  return <section className="section showcase-section" id="features">
    <div className="section-intro"><h2>What you’ll use every day</h2><p>Hover the notch, or press your shortcut, and these are a click away. Agents get their own section below.</p></div>
    <div className="showcase">{showcase.map((item, index) => <article className={`showcase-item ${index % 2 ? 'showcase-item--flip' : ''}`} id={item.id} key={item.id}>
      <div className="showcase-copy"><h3>{item.title}</h3><p>{item.text}</p>{item.sub && <><h4>{item.sub.title}</h4><p>{item.sub.text}</p></>}</div>
      <div className="showcase-visual">{item.visual}</div>
    </article>)}</div>
  </section>
}

const agentSessions = [
  { state: 'Needs you', tone: 'ask', title: 'Claude Code · landing-page', detail: 'Bash: npm run build', approval: true },
  { state: 'Working', tone: 'work', title: 'Codex · api', detail: 'Editing src/routes/auth.ts', context: 41, used: '82k / 200k' },
  { state: 'Done', tone: 'done', title: 'Claude Code · docs', detail: 'Updated the install guide', context: 18, used: '36k / 200k' },
]

function AgentMock() {
  return <div className="agent-mock" role="img" aria-label="The Agent tab: a Claude Code permission request with Approve and Deny, a working Codex session at 41% context, and a finished session">
    <div className="agent-mock-head"><span><i /> Agent activity</span><span>3 sessions</span></div>
    {agentSessions.map((s) => <div className="agent-mock-row" key={s.title}>
      <div><span className={`agent-state agent-state--${s.tone}`}>{s.state}</span><b>{s.title}</b><small>{s.detail}</small></div>
      {s.approval
        ? <div className="agent-mock-buttons"><span>Deny</span><span className="agent-approve">Approve</span></div>
        : <div className="agent-meter"><span><i style={{ width: `${s.context}%` }} /></span><small>{s.context}% · {s.used}</small></div>}
    </div>)}
  </div>
}

const agentSteps = [
  ['Start a task from the notch', 'Drop a project folder on the notch or pick one, then choose Codex, Claude Code, Grok, Command Code or PI: whichever CLI you already use.'],
  ['See every session in one list', 'Codex and Claude Code sessions on your Mac appear on their own, including ones started in Terminal, with what each is doing and how full its context is.'],
  ['Approve or deny in the notch', 'Permission requests show up as a card with Approve and Deny. NotchFlow never answers for you; if it’s closed, the agent asks in its own terminal.'],
  ['Follow up or resume', 'Send the next instruction in the same thread, resume after an interruption, or open the run in its own window.'],
]

function AgentSection() {
  return <section className="agents" id="agents">
    <div className="agents-orb" />
    <div className="agents-copy">
      <h2>Your coding agents, in the notch</h2>
      <p>The Agent tab lists every Codex and Claude Code session running on your Mac. When one needs a decision, it shows up here, so you can answer without finding the right terminal.</p>
      <ol className="agent-steps">{agentSteps.map(([title, text]) => <li key={title}><h3>{title}</h3><p>{text}</p></li>)}</ol>
    </div>
    <AgentMock />
  </section>
}

// One line icon per benefit, drawn on the same 24px grid and stroke as `icons`.
const benefitIcons = {
  calendar: <><rect x="3.5" y="5" width="17" height="15.5" rx="3" /><path d="M8 3v4M16 3v4M3.5 10h17" /><path d="M8 14h2M14 14h2M8 17h2" /></>,
  timer: <><circle cx="12" cy="13.5" r="7.5" /><path d="M12 9.5v4l2.6 1.6M9.5 2.5h5M12 2.5V6" /></>,
  copyFile: <><rect x="8" y="3.5" width="12" height="13" rx="2.5" /><path d="M16 20.5H6.5A2.5 2.5 0 0 1 4 18V8.5" /><path d="M14 7.5v5M11.8 10.5 14 12.7l2.2-2.2" /></>,
  bell: <><path d="M6 16.5v-5.2a6 6 0 0 1 12 0v5.2l1.6 2H4.4l1.6-2Z" /><path d="M10 21a2 2 0 0 0 4 0" /><circle cx="18.5" cy="5.5" r="2.5" fill="currentColor" stroke="none" /></>,
  airpods: <><path d="M7.5 4.5a3 3 0 0 0-3 3v1.5a3 3 0 0 0 3 3h.5v8.5" /><path d="M16.5 4.5a3 3 0 0 1 3 3v1.5a3 3 0 0 1-3 3H16v8.5" /><path d="M8 7.5V12M16 7.5V12" /></>,
  power: <><path d="M12 3v8.5" /><path d="M7.1 6.2a7.5 7.5 0 1 0 9.8 0" /></>,
  camera: <><rect x="3" y="6.5" width="13" height="11" rx="2.5" /><path d="m16 11 5-3v8l-5-3" /><circle cx="9.5" cy="12" r="2" /></>,
  display: <><rect x="2.5" y="4" width="19" height="13" rx="2" /><path d="M9.5 4h5v1.4a1 1 0 0 1-1 1h-3a1 1 0 0 1-1-1V4ZM8.5 21h7M12 17v4" /></>,
  sliders: <><path d="M4 7h9M17 7h3M4 17h3M11 17h9" /><circle cx="15" cy="7" r="2" /><circle cx="9" cy="17" r="2" /></>,
  slashKey: <><rect x="3" y="4.5" width="18" height="15" rx="3.5" /><path d="m13.5 8.5-3 7" /></>,
  forceClick: <><rect x="3" y="5" width="18" height="14" rx="3" /><circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none" /><circle cx="12" cy="12" r="4.2" opacity=".55" /></>,
  tearOff: <><rect x="3" y="8" width="11" height="12" rx="2.5" /><path d="M10 4.5h7.5a2.5 2.5 0 0 1 2.5 2.5V14" /><path d="M14 10l6-6M15.5 4H20v4.5" /></>,
  pen: <><path d="M4 20c2.5-1.5 4-3.5 5.5-3.5S11 19 13 19s3-2 4.5-2 2 1 2.5 1.5" /><path d="M13.5 4.5 17 8l-7 7H6.5v-3.5l7-7Z" /></>,
}

const benefits = [
  { group: 'Everyday', items: [
    ['Calendar & meetings', 'Your next events beside the date, time and weather, with a Join button for Zoom, Meet, Teams, Webex or FaceTime.', 'calendar'],
    ['Pomodoro', 'A focus timer that traces its lap around the notch’s edge and counts the days in a row you finished a session.', 'timer'],
    ['Copy to file', 'Copy something worth keeping and the notch offers to file it. Press ⌘C again to accept; ignore it and it goes away.', 'copyFile'],
    ['Notifications', 'New notifications show beside the notch with the app’s icon and its unread count.', 'bell'],
    ['AirPods & devices', 'A notice when your AirPods connect, and battery levels for what’s paired.', 'airpods'],
    ['Power', 'Keep the Mac awake, sleep the display or start the screensaver.', 'power'],
    ['Mirror', 'A webcam preview before a call. The camera turns on only when you open it.', 'camera'],
    ['Any display', 'No notch? NotchFlow draws one on Macs without a notch and on external displays.', 'display'],
  ] },
  { group: 'When you ask', items: [
    ['Plain-language settings', '“Turn off live activity” or “save my notes as Markdown”: one Confirm and the setting changes.', 'sliders'],
    ['Prompt shortcuts and /', 'Bind a saved instruction to a key and run it on text selected in any app. Type / to switch destination or run a shortcut.', 'slashKey'],
    ['Force Click to compose', 'Optional: press firmly on the trackpad anywhere and the composer opens from the press.', 'forceClick'],
    ['Tear it off', 'Pull a conversation or a running agent task out of the notch into its own window.', 'tearOff'],
    ['Handwritten answers', 'Answers can look written by hand. Switch it on in Settings.', 'pen'],
  ] },
]

function Benefits() {
  return <section className="section benefits-section" id="more">
    <div className="section-intro"><h2>Also in NotchFlow</h2></div>
    <div className="benefits">{benefits.map((g) => <div key={g.group}><h3 className="benefits-group">{g.group}</h3><dl>{g.items.map(([title, text, icon]) => <div className="benefit" key={title}><dt><span className="benefit-icon"><Icon d={benefitIcons[icon]} className="benefit-glyph" /></span>{title}</dt><dd>{text}</dd></div>)}</dl></div>)}</div>
  </section>
}

const modeRows = [
  ['Media, File tray, Calendar and utilities', true, true],
  ['Notifications, devices and Activity Monitor', true, true],
  ['Notes and reminders from the prompt', true, true],
  ['Chat with your models', false, true],
  ['Agent tasks and approvals', false, true],
  ['AI activity', false, true],
]

function Modes() {
  return <section className="section modes-section" id="modes">
    <div className="section-intro"><h2>Generic mode or Agentic mode</h2><p>Generic mode is media, files, notes and the utilities, with no AI. Agentic mode adds chat, agent tasks, approvals and AI activity. Switching keeps everything you saved.</p></div>
    <div className="modes-table" role="table" aria-label="Generic mode compared with Agentic mode">
      <div className="modes-row modes-row--head" role="row"><span role="columnheader">Included</span><span role="columnheader">Generic</span><span role="columnheader">Agentic</span></div>
      {modeRows.map(([label, generic, agentic]) => <div className="modes-row" role="row" key={label}><span role="cell">{label}</span><span role="cell" className={generic ? 'mode-yes' : 'mode-no'} aria-label={generic ? 'Included' : 'Not included'}>{generic ? '✓' : '–'}</span><span role="cell" className={agentic ? 'mode-yes' : 'mode-no'} aria-label={agentic ? 'Included' : 'Not included'}>{agentic ? '✓' : '–'}</span></div>)}
    </div>
  </section>
}

const byok = [
  { title: 'AI providers', note: 'Your own key. Prompts go straight to the provider.', items: ['OpenRouter', 'Vercel AI Gateway', 'OpenAI', 'Anthropic', 'Google Gemini', 'DeepSeek', 'Qwen', 'Kimi', 'GLM', 'MiniMax', 'MiMo'] },
  { title: 'Local & self-hosted', note: 'Any OpenAI-compatible endpoint. A key is optional.', items: ['Ollama', 'LM Studio', 'vLLM', 'Your own gateway'] },
  { title: 'CLIs you’re signed in to', note: 'NotchFlow runs the CLI you installed; its sign-in stays with it.', items: ['Codex', 'Claude Code', 'Grok', 'Command Code', 'PI'] },
  { title: 'Web search', note: 'Optional, with your own key.', items: ['Exa', 'Keenable', 'AnySearch'] },
]

function Models() {
  return <section className="section models-section" id="models">
    <div className="section-heading section-heading--center"><h2>Bring your own key, local model or CLI</h2><p className="section-sub">There’s no NotchFlow account. Connect a provider, point it at a local model, or use a CLI you already use.</p></div>
    <div className="models-grid">{byok.map((group) => <article className="models-card" key={group.title}><h3>{group.title}</h3><p>{group.note}</p><div className="chip-row">{group.items.map((item) => <span className="chip" key={item}>{item}</span>)}</div></article>)}</div>
  </section>
}

function TrustSection() {
  return <section className="section trust-section" id="privacy">
    <div className="trust-intro"><h2>Your data stays on your Mac</h2><p>NotchFlow has no account and no server of its own. Your prompts, history, notes, files and agent records stay on your Mac. Requests go directly to the provider, CLI or search service you choose.</p><a className="inline-link" href={privacyHref}>Read the privacy policy <Arrow /></a></div>
    <div className="trust-grid">
      <article><h3>No NotchFlow server</h3><p>Nothing you type passes through us. Use a provider, a local endpoint or a CLI that’s already signed in.</p></article>
      <article><h3>You see what you send</h3><p>Attachments and selected text are shown in the prompt before anything goes out.</p></article>
      <article><h3>No auto-approve</h3><p>An agent’s permission request waits for your Approve or Deny.</p></article>
    </div>
  </section>
}

const installCommand = 'curl -fsSL https://raw.githubusercontent.com/sidhxntt/notchflow/main/install.sh | bash'
const agentInstallPrompt = `Please install NotchFlow for macOS for me. Run this in my terminal:\n${installCommand}\nIt is a direct-download menu-bar app (${REPO}). After it finishes, confirm NotchFlow is installed in /Applications and launch it.`

function CopyButton({ text }) {
  const [state, setState] = useState('idle')
  const copy = async () => {
    try { await navigator.clipboard.writeText(text); setState('copied') } catch { setState('failed') }
    setTimeout(() => setState('idle'), 2200)
  }
  const label = { idle: 'Copy', copied: 'Copied', failed: 'Select and copy' }[state]
  return <button type="button" className="copy-button" onClick={copy}>{label}</button>
}

function Install() {
  return <section className="section install-section" id="install">
    <div className="install-copy"><h2>Install</h2><p>Download the DMG, drag NotchFlow to Applications and open it. The seven-day trial starts on first launch; no account or payment needed.</p>
      <ul className="install-reqs"><li>macOS 14 Sonoma or later</li><li>Apple-silicon Mac</li><li>A hardware notch is optional</li><li>Developer ID-signed and notarized by Apple</li></ul>
    </div>
    <div className="install-steps">
      <article className="install-card"><h3>Download the DMG</h3><p>The usual install. A matching ZIP is on the release page for Macs that can’t mount a disk image.</p><DownloadButton label="Download the DMG" className="button--small" /></article>
      <article className="install-card"><h3>Or use Terminal</h3><p>A one-line installer that downloads, verifies and installs the latest release.</p><div className="code-line"><code>{installCommand}</code><CopyButton text={installCommand} /></div></article>
      <article className="install-card"><h3>Or ask your agent</h3><p>Paste this into Claude Code or Codex and let it do the install.</p><div className="code-line code-line--prompt"><code>Please install NotchFlow for macOS for me…</code><CopyButton text={agentInstallPrompt} /></div></article>
    </div>
  </section>
}

function LicenseSection() {
  return <section className="section license-section" id="license">
    <div className="license-orb license-orb--one" /><div className="license-orb license-orb--two" />
    <div className="license-copy"><h2>Seven days free, then a one-time license</h2><p>Every new install gets the full app for seven days. After that, NotchFlow asks for a license key before it opens the notch again; your notes, history and settings stay on your Mac. A license is a single purchase, not a subscription, and includes future updates.</p><DownloadButton label="Start the free trial" /></div>
    <div className="license-points"><div><strong>7</strong><span>days with every feature</span></div><div><strong>1</strong><span>payment, updates included</span></div><p>Direct download. No NotchFlow account.</p></div>
  </section>
}

function FAQ() {
  const [active, setActive] = useState(0)
  return <section className="section faq-section" id="faq">
    <div className="faq-heading"><h2>FAQ</h2><p>Didn’t find your answer? Open an issue on GitHub.</p><a className="inline-link" href={`${REPO}/issues`} target="_blank" rel="noreferrer">Ask on GitHub <Arrow /></a></div>
    <div className="faq-list">{faqs.map(([question, answer], index) => <article className="faq-item" key={question}><button type="button" aria-expanded={active === index} onClick={() => setActive(active === index ? -1 : index)}><span>{question}</span><span className="faq-plus" aria-hidden="true">{active === index ? '−' : '+'}</span></button><div className={`faq-answer ${active === index ? 'faq-answer--open' : ''}`}><p>{answer}</p></div></article>)}</div>
  </section>
}

function Footer() {
  return <footer className="footer">
    <div className="footer-top">
      <div><a className="brand" href="#top"><Mark /><span>NotchFlow</span></a><p>AI, notes, files and coding agents in your Mac’s notch.</p></div>
      <div className="footer-links">
        <div><span>Product</span><a href="#features">Features</a><a href="#agents">Agents</a><a href="#models">Models</a><a href="#license">Pricing</a></div>
        <div><span>Resources</span><a href="#install">Install</a><a href="#faq">FAQ</a><a href={`${REPO}/blob/main/CHANGELOG.md`} target="_blank" rel="noreferrer">Changelog</a><a href={`${REPO}/releases`} target="_blank" rel="noreferrer">Releases</a><a href={`${REPO}/issues`} target="_blank" rel="noreferrer">Support</a></div>
        <div><span>Legal</span><a href={privacyHref}>Privacy</a><a href={`${REPO}/blob/main/LICENSE`} target="_blank" rel="noreferrer">Source license</a><a href={REPO} target="_blank" rel="noreferrer">GitHub</a></div>
      </div>
    </div>
    <div className="footer-bottom"><span>© 2026 NotchFlow</span><span>Built for macOS</span></div>
  </footer>
}

function App() { return <><Header /><main><Hero /><Features /><AgentSection /><Benefits /><Modes /><Models /><TrustSection /><Install /><LicenseSection /><FAQ /></main><Footer /></> }
export default App
