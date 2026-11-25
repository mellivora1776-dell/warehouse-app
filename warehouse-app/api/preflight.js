import { handleDocument } from './intake.js'

export default function preflight(req, res) {
  return handleDocument(req, res, true)
}
