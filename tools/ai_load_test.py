# Нагрузочный тест ИИ-проверки через YandexGPT.
# Запуск: YANDEX_API_KEY=... YANDEX_FOLDER_ID=... python3 tools/ai_load_test.py
# Путь к исходникам берётся относительно этого файла.
import json, os, re, time, urllib.request, statistics
from concurrent.futures import ThreadPoolExecutor
src=open(os.path.join(os.path.dirname(__file__),'..','Sources','SmartLayout','AIClient.swift'),encoding='utf-8').read()
hs=open(os.path.join(os.path.dirname(__file__),'..','Sources','SmartLayout','HumanStyle.swift'),encoding='utf-8').read()
def lit(src,name):
    m=re.search(name+r' = """\n(.*?)\n    """',src,re.S); return re.sub(r'\\\n\s*','',m.group(1)).replace('\n    ','\n').strip()
prompt=lit(src,'reviewPrompt')+"\n"+lit(hs,'rules')
KEY=os.environ['YANDEX_API_KEY'];F=os.environ['YANDEX_FOLDER_ID']
def call(text, conv="", next_=True):
    parts=["Приложение: Telegram"]
    if conv: parts.append("Память разговора (последние минуты), только для понимания (НЕ исправлять и НЕ выводить):\n<<<\n"+conv+"\n>>>")
    if next_: parts.append("Предложи продолжение (поле next).")
    parts.append("Текст для обработки:\n<<<\n"+text+"\n>>>")
    body={"model":f"gpt://{F}/yandexgpt/latest","temperature":0.2,"messages":[{"role":"system","content":prompt},{"role":"user","content":"\n\n".join(parts)}]}
    req=urllib.request.Request("https://llm.api.cloud.yandex.net/v1/chat/completions",data=json.dumps(body).encode(),headers={"Content-Type":"application/json","Authorization":f"Api-Key {KEY}","x-folder-id":F})
    t0=time.time()
    try:
        c=json.load(urllib.request.urlopen(req,timeout=40))["choices"][0]["message"]["content"]
        m=re.search(r'\{.*\}',c,re.S); ok=False; obj=None
        if m:
            try: obj=json.loads(m.group(0)); ok='fixed' in obj
            except: pass
        return time.time()-t0, ("ok" if ok else "badjson"), obj
    except urllib.error.HTTPError as e:
        return time.time()-t0, f"http{e.code}", None
    except Exception as e:
        return time.time()-t0, "err:"+type(e).__name__, None
short=["привет как дела че делаешь","я тут подумал что надо встретится завтра","скинь пж скрин где баг","ок давай тогда в пять у метро","слушай а ты отчет уже отправил или нет"]
# 1 sequential
res=[call(short[i%5]) for i in range(10)]
lat=[r[0] for r in res]; print("SEQ 10: p50=%.2fs max=%.2fs statuses=%s"%(statistics.median(lat),max(lat),[r[1] for r in res]))
# 2 concurrent burst
with ThreadPoolExecutor(10) as ex: res=list(ex.map(lambda i: call(short[i%5]), range(10)))
lat=[r[0] for r in res]; print("BURST 10 parallel: p50=%.2fs max=%.2fs statuses=%s"%(statistics.median(lat),max(lat),[r[1] for r in res]))
# 3 long text 3000 chars
long_text=("короче я вчера весь день сидел над проектом и так и не понял почему тесты падают вроде все сделал как надо но чет не работает "*25)[:3000]
r=call(long_text); print("LONG 3000: %.2fs %s fixed_len=%s"%(r[0],r[1],len(r[2]['fixed']) if r[2] else None))
# 4 with conversation memory + next
conv="Собеседник: Ты придёшь сегодня на созвон в 6?\nСобеседник: Нам надо обсудить релиз\nЯ: да конечно"
r=call("слушай а можно перенести на 7 а то я не успеваю", conv); print("MEMORY+NEXT: %.2fs %s"%(r[0],r[1])); print(json.dumps(r[2],ensure_ascii=False,indent=1) if r[2] else "")
