import { useCallback, useEffect, useState } from "react"
import qrcode from "qrcode-generator"
import { Download, History as HistoryIcon, Laptop, Moon, Smartphone, Sun, TabletSmartphone } from "lucide-react"
import {
  Button, CopyButton, Dialog, DialogClose, Divider, Facts, IconButton, Menu, Notice, Row, Skeleton,
  Stack, State, Statement, Tag, Text, Value, useTheme,
} from "kiln"

/* What /api/state answers (server.mjs). */
interface Device { id: string; name: string; connected: boolean; lastSeen: string; connectedAt?: string; client?: string }
interface Hub {
  error?: string
  files: number; bytes: number; historyFiles: number; historyBytes: number; historyLatest?: string
  uptimeS: number; folderErrors: number; devices: Device[] | null
}
interface State_ {
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

// iPads say Macintosh too; they have touch.
const onMac = /Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints < 2
const onPhone = /iPhone|iPad/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1)

export function App() {
  const [st, setSt] = useState<State_ | null>(null)
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

  const devices = st?.hub.devices ?? []
  return (
    <div className="mp">
      <header className="mp-bar">
        <Row gap={2}>
          <img className="mp-mark" src="/icon.png" alt="" width={32} height={32} />
          <Text as="span" size="label">Magpie</Text>
          {st?.sample && <Tag tone="sunk">Sample data</Tag>}
        </Row>
        <ThemeMenu />
      </header>

      <main className="mp-main">
        {failed && !st && <Notice tone="danger" title="This page can't reach its server">It tries again every 30 seconds.</Notice>}
        {!st && !failed && <Stack gap={4} aria-busy="true" aria-label="Checking Frankfurt"><Skeleton width="70%" height={56} /><Skeleton lines={3} /></Stack>}
        {st && (
          <>
            <Hero st={st} />
            <History hub={st.hub} />
            <Divider />
            <Devices devices={devices} reload={load} />
            <Divider />
            <AddDevice st={st} first={devices.length === 0} reload={load} />
            <Divider />
            <GetMagpie st={st} hasDevices={devices.length > 0} />
          </>
        )}
      </main>

      <footer className="mp-foot">
        {checked && <Text size="caption" tone="subtle">Checked at <Value>{clock(checked)}</Value>, again every 30 seconds</Text>}
      </footer>
    </div>
  )
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

/* The server's state is the first thing on the page. */
function Hero({ st }: { st: State_ }) {
  const h = st.hub
  if (h.error)
    return (
      <section className="mp-hero">
        <State kind="failed">Not answering</State>
        <Statement level={1} size="title-1" title="Frankfurt isn't answering">{h.error}</Statement>
      </section>
    )
  const [state, kind, title, why] = !st.open
    ? ["Unreachable", "failed", "Frankfurt is running, out of reach", "Port 22000 has to be open for TCP and UDP in Oracle Cloud before your devices can connect."]
    : h.folderErrors
      ? ["Needs a look", "failed", "Frankfurt can't save some files", "The weekly check on the server looks into it and tells you."]
      : ["Live", "live", "Frankfurt is keeping your files", "Encrypted with a key only your devices have."]
  return (
    <section className="mp-hero">
      <State kind={kind as "live" | "failed"}>{state}</State>
      <Statement level={1} size="title-1" title={title}>{why}</Statement>
      <Facts
        items={[
          ["Files", <Value key="f">{h.files.toLocaleString()}</Value>],
          ["Stored, encrypted", <Value key="b">{bytes(h.bytes)}</Value>],
          ["Running for", <Value key="u">{span(h.uptimeS)}</Value>],
        ]}
      />
    </section>
  )
}

function History({ hub }: { hub: Hub }) {
  if (hub.error) return null
  const has = hub.historyFiles > 0
  return (
    <section className="mp-section">
      <Statement title="Older versions">
        {has
          ? `Frankfurt keeps ${plural(hub.historyFiles, "older version", "older versions")}, ${bytes(hub.historyBytes)}${hub.historyLatest ? `, the newest kept ${ago(hub.historyLatest)}` : ""}. Browse and restore them in Magpie.`
          : "None yet. When a file changes or is deleted, the version before is kept here for a year."}
      </Statement>
      <div>
        <Button variant="outline" size="sm" icon={<HistoryIcon />} onClick={() => (location.href = "magpie1:history")}>Browse in Magpie</Button>
      </div>
    </section>
  )
}

function deviceIcon(name: string) {
  if (/iphone/i.test(name)) return <Smartphone />
  if (/ipad/i.test(name)) return <TabletSmartphone />
  return <Laptop />
}

function Devices({ devices, reload }: { devices: Device[]; reload: () => void }) {
  const [removing, setRemoving] = useState<Device | null>(null)
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
  return (
    <section className="mp-section">
      <Statement title="Devices">Each one holds the key. The server only passes encrypted files between them.</Statement>
      {devices.length === 0
        ? <Text tone="muted">No devices yet.</Text>
        : (
          <ul className="mp-list">
            {devices.map((d) => (
              <li key={d.id} className="mp-item">
                <span className="mp-item__icon" aria-hidden>{deviceIcon(d.name)}</span>
                <div className="mp-item__body">
                  <Text as="span" size="label">{d.name || d.id.slice(0, 7)}</Text>
                  <Text size="body-sm" tone="muted">
                    {d.connected
                      ? d.connectedAt ? <>Connected since <Value>{clock(d.connectedAt)}</Value></> : "Connected now"
                      : d.lastSeen && !d.lastSeen.startsWith("1970") ? <>Last seen <Value>{ago(d.lastSeen)}</Value></> : "Not seen yet"}
                  </Text>
                </div>
                <div className="mp-item__end">
                  <State kind={d.connected ? "live" : "idle"}>{d.connected ? "Online" : "Offline"}</State>
                  <Button variant="ghost" size="sm" onClick={() => { setProblem(null); setRemoving(d) }}>Remove</Button>
                </div>
              </li>
            ))}
          </ul>
        )}
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
    </section>
  )
}

function AddDevice({ st, first, reload }: { st: State_; first: boolean; reload: () => void }) {
  const [link, setLink] = useState<{ link: string; expires: string } | null>(null)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)

  if (!first)
    return (
      <section className="mp-section">
        <Statement title="Add a device">
          {onMac ? "Opens Add Device in Magpie on this Mac. Scan its code with Magpie on your iPhone." : "On your Mac, open this page and choose Add a device, or choose Add Device… from Magpie in the menu bar."}
        </Statement>
        {onMac && <div><Button variant="ink" onClick={() => (location.href = "magpie1:add-device")}>Add a device</Button></div>}
        <Text size="caption" tone="subtle">The code carries your encryption key, which only your devices have, so it comes from the Mac and not from this page. If nothing opens, update Magpie on the Mac first.</Text>
      </section>
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
    <section className="mp-section">
      <Statement title="Set up your first device">
        {waiting.length
          ? `You can make a setup link once ${waiting.join(" and ")}.`
          : "Paste this link into Magpie, or scan it with your iPhone. It works once, for 15 minutes. This first device makes the encryption key; add the rest from it."}
      </Statement>
      <div><Button variant="ink" loading={busy} disabled={waiting.length > 0} onClick={make}>{link ? "Make a new link" : "Make a setup link"}</Button></div>
      {problem && <Notice tone="danger" title={problem} />}
      {link && (
        <Row gap={5} align="start" wrap>
          <div className="mp-qr" aria-label="Setup link as a QR code" dangerouslySetInnerHTML={{ __html: svg }} />
          <Stack gap={3}>
            <CopyButton value={link.link} variant="outline">Copy the link</CopyButton>
            <Text size="caption" tone="subtle">Works once, until <Value>{clock(link.expires)}</Value>.</Text>
          </Stack>
        </Row>
      )}
    </section>
  )
}

function GetMagpie({ st, hasDevices }: { st: State_; hasDevices: boolean }) {
  return (
    <section className="mp-section">
      <Statement title="Get Magpie">For your Mac and your iPhone.</Statement>
      <ul className="mp-list">
        <li className="mp-item mp-item--top">
          <span className="mp-item__icon" aria-hidden><Laptop /></span>
          <div className="mp-item__body">
            <Text as="span" size="label">Mac</Text>
            {st.mac
              ? <Facts layout="stack" className="mp-meta" items={[["Version", <Value key="v">{st.mac.version}</Value>], ["Size", <Value key="s">{bytes(st.mac.size)}</Value>], ["Needs", "macOS 14+"]]} />
              : <Text size="body-sm" tone="muted">The first build is on its way.</Text>}
          </div>
          {st.mac && <div className="mp-item__end"><Button variant="outline" icon={<Download />} onClick={() => (location.href = st.mac!.url)}>Download</Button></div>}
          {st.mac && hasDevices && <Text className="mp-item__note" size="caption" tone="subtle">Already installed? Magpie updates itself. Quit Magpie before opening a new download.</Text>}
        </li>
        <li className="mp-item mp-item--top">
          <span className="mp-item__icon" aria-hidden><Smartphone /></span>
          <div className="mp-item__body">
            <Text as="span" size="label">iPhone</Text>
            <Facts layout="stack" className="mp-meta" items={[["From", "TestFlight"], ["Needs", "iOS 17+"]]} />
          </div>
          {onPhone && st.iphone && <div className="mp-item__end"><Button variant="outline" onClick={() => (location.href = "itms-beta://")}>Open TestFlight</Button></div>}
          {!onPhone && <Text className="mp-item__note" size="caption" tone="subtle">Open TestFlight on your iPhone; Magpie is waiting there.</Text>}
        </li>
      </ul>
    </section>
  )
}
