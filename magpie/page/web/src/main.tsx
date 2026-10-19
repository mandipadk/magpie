import "@fontsource-variable/mona-sans/wdth.css"
import "@fontsource-variable/martian-mono"
import "kiln/styles.css"
import "./page.css"
import { StrictMode } from "react"
import { createRoot } from "react-dom/client"
import { KilnProvider } from "kiln"
import { App } from "./app"

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <KilnProvider>
      <App />
    </KilnProvider>
  </StrictMode>,
)
