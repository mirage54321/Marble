Option Explicit

Dim matchName, suggested, choices, prompt, answer
matchName = WScript.Arguments(0)
suggested = WScript.Arguments(1)
choices = Replace(WScript.Arguments(2), "|", ", ")

prompt = "Marble found a finished robot log for " & matchName & "." & vbCrLf & vbCrLf & _
  "Which battery was in the robot?" & vbCrLf & _
  "Available batteries: " & choices & vbCrLf & vbCrLf & _
  "Choose the suggested battery or type another label."
answer = InputBox(prompt, "Marble Collector", suggested)

If answer = "" Then
  WScript.Echo "__CANCEL__"
Else
  WScript.Echo Trim(answer)
End If
