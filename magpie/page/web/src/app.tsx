import { useCallback, useEffect, useState, type ReactNode } from "react"
import qrcode from "qrcode-generator"
import { Download, History as HistoryIcon, Laptop, Moon, Plus, Smartphone, Sun, TabletSmartphone } from "lucide-react"
import {
  Button, CopyButton, Dialog, DialogClose, EmptyState, Heading, IconButton, Menu, Notice, Skeleton,
  Stat, Surface, Table, Tag, Text, Value, useTheme, type Column,
} from "kiln"

/* What /api/state answers (server.mjs). */
interface Device { id: string; name: string; connected: boolean; lastSeen: string; connectedAt?: string; client?: string }
interface Hub {
  error?: string
  files: number; bytes: number; historyFiles: number; historyBytes: number; historyLatest?: string
  uptimeS: number; folderErrors: number; devices: Device[] | null
}
interface PageState {
  hub: Hub; open: boolean; sample: boolean
  mac: { url: string; version: string; size: number } | null
  iphone: { url: string } | null
}

const post = (path: string, body: object = {}) =>
  fetch(path, { method: "POST", headers: { "Content-Type": "application/json", "X-Magpie": "1" }, body: JSON.stringify(body) }).then((r) => r.json())

/* Words for numbers and times */

const bytes = (n: number) => {
  if (n < 1000) return `${n} bytes`
  const u = ["KB", "MB", "GB", "TB"]
  let i = -1
  do { n /= 1000; i++ } while (n >= 1000 && i < u.length - 1)
  return `${n.toFixed(n < 10 ? 2 : n < 100 ? 1 : 0)} ${u[i]}`
}
const plural = (n: number, one: string, many: string) => `${n.toLocaleString()} ${n === 1 ? one : many}`
const span = (s: number) =>
  s < 3600 ? plural(Math.max(1, Math.round(s / 60)), "minute", "minutes")
    : s < 86400 * 2 ? plural(Math.round(s / 3600), "hour", "hours")
      : plural(Math.round(s / 86400), "day", "days")
const ago = (iso: string) => {
  const s = (Date.now() - new Date(iso).getTime()) / 1000
  return s < 90 ? "just now" : `${span(s)} ago`
}
const clock = (iso: string | Date) => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
const seen = (iso?: string) => !!iso && !iso.startsWith("1970") && !iso.startsWith("0001")

// iPads say Macintosh too; they have touch.
const onMac = /Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints < 2
const onPhone = /iPhone|iPad/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1)

export function App() {
  const [st, setSt] = useState<PageState | null>(null)
  const [failed, setFailed] = useState(false)
  const [checked, setChecked] = useState<Date | null>(null)

  const load = useCallback(async () => {
    try {
      const r = await fetch("api/state")
      setSt(await r.json())
      setFailed(false)
      setChecked(new Date())
    } catch {
      setFailed(true)
    }
  }, [])
  useEffect(() => {
    load()
    const t = setInterval(load, 30000)
    return () => clearInterval(t)
  }, [load])

  return (
    <div className="mp">
      <header className="mp-bar">
        <div className="mp-bar__brand">
          <img className="mp-mark" src="/icon.png" alt="" width={28} height={28} />
          <Text as="span" size="label">Magpie</Text>
          {st && <HubTag st={st} />}
          {st?.sample && <Tag tone="sunk">Sample data</Tag>}
        </div>
        <ThemeMenu />
      </header>

      <main className="mp-main">
        {failed && !st && <Notice tone="danger" title="This page can't reach its server">It tries again every 30 seconds.</Notice>}
        {!st && !failed && <Loading />}
        {st && st.hub.error && (
          <Notice tone="danger" title="Frankfurt isn't answering">{st.hub.error}</Notice>
        )}
        {st && !st.hub.error && (
          <>
            {!st.open && <Notice tone="warning" title="Your devices can't reach Frankfurt">Port 22000 has to be open for TCP and UDP in Oracle Cloud.</Notice>}
            {st.hub.folderErrors > 0 && <Notice tone="warning" title="Frankfurt can't save some files">The weekly check on the server looks into it and tells you.</Notice>}
            <div className="mp-stats" aria-label="Frankfurt">
              <Stat label="Files" value={<Value>{st.hub.files.toLocaleString()}</Value>} />
              <Stat label="Stored, encrypted" value={<Value>{bytes(st.hub.bytes)}</Value>} />
              <Stat label="Older versions" value={<Value>{st.hub.historyFiles.toLocaleString()}</Value>} />
              <Stat label="Running for" value={<Value>{span(st.hub.uptimeS)}</Value>} />
            </div>
            <Devices st={st} reload={load} />
            <div className="mp-pair">
              <Versions hub={st.hub} />
              <GetMagpie st={st} />
            </div>
          </>
        )}
      </main>

      <footer className="mp-foot">
        {checked && <Text size="caption" tone="subtle">Checked at <Value>{clock(checked)}</Value></Text>}
      </footer>
    </div>
  )
}

function Loading() {
  return (
    <div className="mp-stats" aria-busy="true" aria-label="Checking Frankfurt">
      {[0, 1, 2, 3].map((i) => <Skeleton key={i} height={64} />)}
    </div>
  )
}

/* The server's state, as a tag next to the name. */
function HubTag({ st }: { st: PageState }) {
  if (st.hub.error) return <Tag tone="outline">Not answering</Tag>
  if (!st.open) return <Tag tone="outline">Unreachable</Tag>
  if (st.hub.folderErrors) return <Tag tone="outline">Needs a look</Tag>
  return <Tag tone="accent">Running</Tag>
}

function ThemeMenu() {
  const { theme, setTheme, resolved } = useTheme()
  return (
    <Menu
      align="end"
      trigger={<IconButton label="Theme" variant="ghost">{resolved === "dark" ? <Moon /> : <Sun />}</IconButton>}
      items={[
        { kind: "check", label: "Match the system", checked: theme === "system", onCheckedChange: () => setTheme("system") },
        { kind: "check", label: "Light", checked: theme === "light", onCheckedChange: () => setTheme("light") },
        { kind: "check", label: "Dark", checked: theme === "dark", onCheckedChange: () => setTheme("dark") },
      ]}
    />
  )
}

function Panel({ title, action, children }: { title: string; action?: ReactNode; children: ReactNode }) {
  return (
    <Surface as="section" tone="flat" pad="md" className="mp-panel" aria-label={title}>
      <div className="mp-panel__head">
        <Heading level={2} size="label">{title}</Heading>
        {action}
      </div>
      {children}
    </Surface>
  )
}

function deviceIcon(name: string) {
  if (/iphone/i.test(name)) return <Smartphone />
  if (/ipad/i.test(name)) return <TabletSmartphone />
  return <Laptop />
}

function Devices({ st, reload }: { st: PageState; reload: () => void }) {
  const devices = st.hub.devices ?? []
  const [removing, setRemoving] = useState<Device | null>(null)
  const [adding, setAdding] = useState(false)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)

  const remove = async () => {
    if (!removing) return
    setBusy(true); setProblem(null)
    try {
      const r = await post("api/remove", { id: removing.id })
      if (r.error) throw new Error(r.error)
      setRemoving(null)
      reload()
    } catch (e) {
      setProblem(`Couldn't remove it: ${(e as Error).message}`)
    } finally {
      setBusy(false)
    }
  }

  const columns: Column<Device>[] = [
    {
      key: "name", header: "Device", sortValue: (d) => d.name,
      cell: (d) => (
        <span className="mp-device">
          <span className="mp-device__icon" aria-hidden>{deviceIcon(d.name)}</span>
          <span>{d.name || d.id.slice(0, 7)}</span>
        </span>
      ),
    },
    {
      key: "state", header: "Status", sortValue: (d) => (d.connected ? 0 : 1),
      cell: (d) => <Tag tone={d.connected ? "accent" : "sunk"}>{d.connected ? "Online" : "Offline"}</Tag>,
    },
    {
      key: "when", header: "Last activity", hideBelow: "sm", numeric: true,
      sortValue: (d) => -new Date(d.connected ? Date.now() : d.lastSeen).getTime(),
      cell: (d) => d.connected
        ? (d.connectedAt ? <>Since <Value>{clock(d.connectedAt)}</Value></> : "Now")
        : seen(d.lastSeen) ? <Value>{ago(d.lastSeen)}</Value> : "Never",
    },
    {
      key: "remove", header: "", align: "end", width: "96px",
      cell: (d) => <Button variant="ghost" size="sm" className="mp-quiet" onClick={() => { setProblem(null); setRemoving(d) }} aria-label={`Remove ${d.name}`}>Remove</Button>,
    },
  ]

  return (
    <Panel
      title="Devices"
      action={<Button variant="ink" size="sm" icon={<Plus />} onClick={() => (devices.length > 0 && onMac ? (location.href = "magpie1:add-device") : setAdding(true))}>Add a device</Button>}
    >
      <Table<Device>
        caption="Devices sharing your Magpie"
        columns={columns}
        rows={devices}
        rowKey={(d) => d.id}
        empty={
          <EmptyState icon={<Laptop />} title="No devices yet" action={<Button variant="outline" onClick={() => setAdding(true)}>Set up your first device</Button>}>
            Your first device makes the encryption key; add the rest from it.
          </EmptyState>
        }
      />

      <AddDialog open={adding} onOpenChange={setAdding} st={st} first={devices.length === 0} reload={reload} />

      <Dialog
        open={removing != null}
        onOpenChange={(o) => { if (!o && !busy) setRemoving(null) }}
        alert
        size="sm"
        title={`Remove ${removing?.name || "this device"}?`}
        description="It stops syncing now and can't let itself back in. To use it again, add it from your Mac. Files already on it stay there."
        actions={
          <>
            <DialogClose render={<Button variant="outline">Cancel</Button>} />
            <Button variant="danger" loading={busy} onClick={remove}>Remove</Button>
          </>
        }
      >
        {problem && <Notice tone="danger" title={problem} />}
      </Dialog>
    </Panel>
  )
}

/* The first device gets a link from the server; later ones get their code from the Mac,
   because only devices hold the encryption key. */
function AddDialog({ open, onOpenChange, st, first, reload }: { open: boolean; onOpenChange: (o: boolean) => void; st: PageState; first: boolean; reload: () => void }) {
  const [link, setLink] = useState<{ link: string; expires: string } | null>(null)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)

  if (!first)
    return (
      <Dialog
        open={open}
        onOpenChange={onOpenChange}
        size="sm"
        title="Add a device from your Mac"
        description="A new device needs your encryption key, and only your devices have it. Open this page on your Mac and press Add a device, or choose Add Device… from Magpie in the Mac's menu bar, then scan the code with Magpie on your iPhone."
        actions={<DialogClose render={<Button variant="ink">Done</Button>} />}
      />
    )

  const waiting = [!st.open && "your devices can reach the server", !st.mac && !st.iphone && "Magpie is ready to install"].filter(Boolean)
  const make = async () => {
    setBusy(true); setProblem(null)
    try {
      const r = await post("api/setup-link")
      if (!r.link) throw new Error(r.error || "No link came back.")
      setLink(r)
    } catch (e) {
      setProblem(`Couldn't make a link: ${(e as Error).message}`)
    } finally {
      setBusy(false)
      reload()
    }
  }
  const svg = link ? (() => { const q = qrcode(0, "M"); q.addData(link.link); q.make(); return q.createSvgTag({ cellSize: 4, margin: 0, scalable: true }) })() : ""
  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title="Set up your first device"
      description={waiting.length ? `You can make a setup link once ${waiting.join(" and ")}.` : "Paste the link into Magpie, or scan it with your iPhone. It works once, for 15 minutes."}
      actions={
        <>
          <DialogClose render={<Button variant="outline">Close</Button>} />
          <Button variant="ink" loading={busy} disabled={waiting.length > 0} onClick={make}>{link ? "Make a new link" : "Make a setup link"}</Button>
        </>
      }
    >
      {problem && <Notice tone="danger" title={problem} />}
      {link && (
        <div className="mp-link">
          <div className="mp-qr" aria-label="Setup link as a QR code" dangerouslySetInnerHTML={{ __html: svg }} />
          <div className="mp-link__side">
            <CopyButton value={link.link} variant="outline">Copy the link</CopyButton>
            <Text size="caption" tone="subtle">Works once, until <Value>{clock(link.expires)}</Value>.</Text>
          </div>
        </div>
      )}
    </Dialog>
  )
}

function Versions({ hub }: { hub: Hub }) {
  const has = hub.historyFiles > 0
  return (
    <Panel title="Older versions" action={<Button variant="outline" size="sm" icon={<HistoryIcon />} onClick={() => (location.href = "magpie1:history")}>Browse</Button>}>
      <div className="mp-kv">
        <div><Text as="span" size="caption" tone="muted">Kept</Text><Text as="span" size="body"><Value>{has ? plural(hub.historyFiles, "version", "versions") : "None yet"}</Value></Text></div>
        <div><Text as="span" size="caption" tone="muted">Size</Text><Text as="span" size="body"><Value>{bytes(hub.historyBytes)}</Value></Text></div>
        <div><Text as="span" size="caption" tone="muted">Newest</Text><Text as="span" size="body"><Value>{has && hub.historyLatest ? ago(hub.historyLatest) : "None yet"}</Value></Text></div>
      </div>
      <Text size="caption" tone="subtle">Kept for a year when a file changes or is deleted. Browse opens history in Magpie.</Text>
    </Panel>
  )
}

function GetMagpie({ st }: { st: PageState }) {
  const installed = (st.hub.devices ?? []).length > 0
  return (
    <Panel title="Get Magpie">
      <ul className="mp-apps">
        <li className="mp-app">
          <span className="mp-app__icon" aria-hidden><Laptop /></span>
          <div className="mp-app__body">
            <Text as="span" size="label">Mac</Text>
            <Text as="span" size="caption" tone="muted">{st.mac ? <>Version <Value>{st.mac.version}</Value>, <Value>{bytes(st.mac.size)}</Value>, macOS 14 or later</> : "First build on its way"}</Text>
          </div>
          {st.mac && <Button variant="outline" size="sm" icon={<Download />} onClick={() => (location.href = st.mac!.url)}>Download</Button>}
        </li>
        <li className="mp-app">
          <span className="mp-app__icon" aria-hidden><Smartphone /></span>
          <div className="mp-app__body">
            <Text as="span" size="label">iPhone</Text>
            <Text as="span" size="caption" tone="muted">TestFlight, iOS 17 or later</Text>
          </div>
          <Button variant="outline" size="sm" disabled={!onPhone} onClick={() => (location.href = "itms-beta://")}>Open TestFlight</Button>
        </li>
      </ul>
      {installed && <Text size="caption" tone="subtle">Magpie updates itself once installed. Quit it before opening a new download.</Text>}
      {!onPhone && <Text size="caption" tone="subtle">Open TestFlight works on your iPhone.</Text>}
    </Panel>
  )
}
