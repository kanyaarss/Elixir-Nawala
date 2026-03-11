import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const FLASH_TIMEOUT_MS = 5000
const DISMISSED_FLASH_TTL_MS = 10 * 60 * 1000
const DISMISSED_FLASH_STORAGE_KEY = "dismissed_flash_messages"

const loadDismissedFlashes = () => {
  try {
    const raw = window.sessionStorage.getItem(DISMISSED_FLASH_STORAGE_KEY)
    const parsed = raw ? JSON.parse(raw) : {}

    if (!parsed || typeof parsed !== "object") return {}
    return parsed
  } catch (_err) {
    return {}
  }
}

const saveDismissedFlashes = (payload) => {
  try {
    window.sessionStorage.setItem(DISMISSED_FLASH_STORAGE_KEY, JSON.stringify(payload))
  } catch (_err) {}
}

const pruneDismissedFlashes = () => {
  const now = Date.now()
  const dismissed = loadDismissedFlashes()

  const pruned = Object.fromEntries(
    Object.entries(dismissed).filter(([, expiresAt]) => Number(expiresAt) > now)
  )

  if (Object.keys(pruned).length !== Object.keys(dismissed).length) {
    saveDismissedFlashes(pruned)
  }

  return pruned
}

const flashFingerprint = (el) => {
  if (!(el instanceof Element)) return null

  const kind = el.classList.contains("error") ? "error" : "info"
  const message = el.querySelector(".flash-body p")?.textContent?.trim() || ""

  if (!message) return null
  return `${kind}:${message}`
}

const markFlashDismissed = (el) => {
  const key = flashFingerprint(el)
  if (!key) return

  const dismissed = pruneDismissedFlashes()
  dismissed[key] = Date.now() + DISMISSED_FLASH_TTL_MS
  saveDismissedFlashes(dismissed)
}

const isFlashDismissed = (el) => {
  const key = flashFingerprint(el)
  if (!key) return false

  const dismissed = pruneDismissedFlashes()
  return Number(dismissed[key]) > Date.now()
}

const scheduleFlashRemoval = (el) => {
  if (!el || el.dataset.autoDismissScheduled === "true") return

  if (isFlashDismissed(el)) {
    el.remove()
    return
  }

  el.dataset.autoDismissScheduled = "true"

  window.setTimeout(() => {
    const closeButton = el.querySelector(".flash-close")

    if (closeButton instanceof HTMLElement) {
      markFlashDismissed(el)
      closeButton.click()
    } else {
      markFlashDismissed(el)
      el.remove()
    }
  }, FLASH_TIMEOUT_MS)
}

const wireFlashAutoDismiss = () => {
  document.addEventListener("click", (event) => {
    const target = event.target
    if (!(target instanceof Element)) return

    const closeButton = target.closest(".flash-close")
    if (!closeButton) return

    const flashEl = closeButton.closest(".flash")
    if (!flashEl) return

    markFlashDismissed(flashEl)
    window.setTimeout(() => flashEl.remove(), 100)
  })

  document.querySelectorAll(".flash").forEach(scheduleFlashRemoval)

  const observer = new MutationObserver((mutations) => {
    mutations.forEach((mutation) => {
      mutation.addedNodes.forEach((node) => {
        if (!(node instanceof Element)) return

        if (node.matches(".flash")) {
          scheduleFlashRemoval(node)
          return
        }

        node.querySelectorAll?.(".flash").forEach(scheduleFlashRemoval)
      })
    })
  })

  observer.observe(document.body, {childList: true, subtree: true})
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}})

wireFlashAutoDismiss()

liveSocket.connect()
window.liveSocket = liveSocket
