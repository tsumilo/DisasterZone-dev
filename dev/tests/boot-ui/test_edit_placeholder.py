"""The grey hint in an empty edit box (UI:SetEditPlaceholder): it hides as soon as there is text, also when the
caller sets its own OnTextChanged after the hint (SetScript drops every hook, in the game and in the mock), and comes
back when the box is emptied. The badge designer's Name and Title fields had the hint under the typed text
(2026-10-06, in game).

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_edit_placeholder.py
"""
from _common import case, run_all, solo, no_errors


@case
def the_hint_hides_under_typed_text_even_with_the_callers_own_handler():
    w, c = solo("Rai", guild_rank=0, tick=3)
    shown = c.eval_py("""
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(300, 100)
        local eb = ns.UI:CreateSleekEditBox(f, 200, 26)
        ns.UI:SetEditPlaceholder(eb, "the Duelist")
        T_seen = 0
        eb:SetScript("OnTextChanged", function(self) T_seen = T_seen + 1 end)   -- the caller's, after the hint
        local out = { eb.cdlHint:IsShown() }
        eb:SetText("ewq")
        out[#out + 1] = eb.cdlHint:IsShown()
        eb:SetText("")
        out[#out + 1] = eb.cdlHint:IsShown()
        -- a second handler later on: still hooked
        eb:SetScript("OnTextChanged", function(self) T_seen = T_seen + 10 end)
        eb:SetText("x")
        out[#out + 1] = eb.cdlHint:IsShown()
        out[#out + 1] = T_seen
        return out""")
    assert shown == [True, False, True, False, 12], shown
    no_errors(w)


@case
def the_badge_designers_fields_hide_their_hints():
    w, c = solo("Rai", guild_rank=0, tick=3)
    c.slash("/dz demo on")
    w.tick(1)
    out = c.eval_py("""
        ns.MainFrame:Open("events")
        ns.EventsUI:Open("library")
        local d = ns.Events:GetDef("edemo1")
        local bid = next(d.badges)
        ns.EventsUI:OpenBadgeDesigner(d, bid, function() end)
        local f = ns.EventsUI:GetSheet("badge")
        local out = {}
        for _, eb in ipairs(f.fields or {}) do
          if eb.cdlHint then
            eb:SetText("typed")
            out[#out + 1] = eb.cdlHint:IsShown()
          end
        end
        return out""")
    assert out and not any(out), out
    no_errors(w)


if __name__ == "__main__":
    run_all()
