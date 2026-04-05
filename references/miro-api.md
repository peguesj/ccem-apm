# Miro REST API v2 — Coalesced Reference

**Base URL**: `https://api.miro.com/v2`
**Auth**: `Authorization: Bearer <ACCESS_TOKEN>` (OAuth2 bearer; short-lived access token or dev token from https://developers.miro.com)
**Content-Type**: `application/json` for all write ops
**Rate limit**: typically 100 req/min per app-token combination. 429 response carries `Retry-After` header (seconds).

## Endpoints Used by Mirofish Plugin

### 1. List Boards
- `GET /v2/boards`
- Query: `?limit=50&offset=0&query=<name>`
- Returns: `{data: [{id, name, description, ...}], total, size, offset, limit}`

### 2. Get Board
- `GET /v2/boards/:board_id`
- Returns: `{id, name, description, policy, ...}`

### 3. Create Board
- `POST /v2/boards`
- Body: `{"name": "My Board", "description": "...", "policy": {"permissionsPolicy": {"collaborationToolsStartAccess": "all_editors", "copyAccess": "anyone", "sharingAccess": "team_members_with_editing_rights"}, "sharingPolicy": {"access": "private", "inviteToAccountAndBoardLinkAccess": "no_access", "organizationAccess": "private", "teamAccess": "private"}}}`
- Returns: `{id, name, ...}`

### 4. Create Sticky Note
- `POST /v2/boards/:board_id/sticky_notes`
- Body:
  ```json
  {
    "data": {"content": "Finding text", "shape": "square"},
    "style": {"fillColor": "light_yellow"},
    "position": {"x": 0, "y": 0, "origin": "center"},
    "geometry": {"width": 200}
  }
  ```
- `shape`: `square` | `rectangle`
- `fillColor`: `gray`, `light_yellow`, `yellow`, `orange`, `light_green`, `green`, `dark_green`, `cyan`, `light_pink`, `pink`, `violet`, `red`, `light_blue`, `blue`, `dark_blue`, `black`
- Returns: `{id, type: "sticky_note", data, style, position, geometry, ...}`

### 5. Create Frame
- `POST /v2/boards/:board_id/frames`
- Body:
  ```json
  {
    "data": {"title": "Research Findings", "format": "custom", "type": "freeform"},
    "position": {"x": 0, "y": 0, "origin": "center"},
    "geometry": {"width": 800, "height": 600}
  }
  ```
- Returns: `{id, type: "frame", data, ...}`

### 6. Create Text
- `POST /v2/boards/:board_id/texts`
- Body:
  ```json
  {
    "data": {"content": "<p>Header</p>"},
    "style": {"fontSize": "24", "textAlign": "center"},
    "position": {"x": 0, "y": 0},
    "geometry": {"width": 400}
  }
  ```

### 7. List Items on Board
- `GET /v2/boards/:board_id/items?limit=50`
- Returns: `{data: [{id, type, ...}], total, ...}`

### 8. Delete Item
- `DELETE /v2/boards/:board_id/items/:item_id`
- Returns: 204 No Content

## Error Shapes

- 401: `{"type": "error", "code": "unauthorized", "message": "..."}`
- 404: `{"type": "error", "code": "board_not_found", ...}`
- 429: Rate limit; respect `Retry-After` header (seconds).

## Token Sources

In order of precedence:
1. `MIRO_ACCESS_TOKEN` env var
2. `~/.config/mirofish/token` file (single line, trimmed)
3. Return `{:error, :no_token}` if neither is set
