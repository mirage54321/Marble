Option Explicit

Dim matchName, timeRange, suggested, choices, prompt, answer
matchName = WScript.Arguments(0)
timeRange = WScript.Arguments(1)
suggested = WScript.Arguments(2)
choices = Replace(WScript.Arguments(3), "|", ", ")

prompt = "Marble found a finished robot log for " & matchName & "." & vbCrLf & vbCrLf & _
  "Robot enabled: " & timeRange & vbCrLf & vbCrLf & _
  "Which battery was in the robot?" & vbCrLf & _
  "Available batteries: " & choices & vbCrLf & vbCrLf & _
  "Choose the suggested battery or type another label." & vbCrLf & _
  "Type ? if you don't know yet."
answer = InputBox(prompt, "Marble Collector", suggested)

If answer = "" Then
  WScript.Echo "__CANCEL__"
ElseIf Trim(answer) = "?" Then
  WScript.Echo "__UNKNOWN__"
Else
  WScript.Echo Trim(answer)
End If
