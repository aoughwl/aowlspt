# F5-TTS shouted clips -- how each one was made

Baseline = `f5tts-2.wav` (kept verbatim as `data/voices/keep-f5-yell.wav`, md5 cbd7c0a62e8a98d33d89c56f28ad9ed1): model F5TTS_v1_Base, ref `placeholder-sapi-david.wav` with its whisper transcript as ref_text, nfe_step 32, cfg_strength 2.0, speed 1.0, seed RANDOM AND NOT RECORDED (bench_f5.py did not print it -- that clip cannot be regenerated bit-for-bit), then post-process `yellify`: gain +6 dB, RBJ high-shelf +4 dB @ 3 kHz, tanh soft clip (x1.2, normalised).

Every clip below records its seed. Regenerate one with
`tools/f5tts/yells.py --model M --ref R --nfe N --seed S --line K --start <n>` (run with the f5tts venv python).

| file | style | model | ref | nfe | cfg | seed | gen ms | audio s | text |
|---|---|---|---|---|---|---|---|---|---|
| f5tts-yell-1.wav | threat | F5TTS_v1_Base | david | 32 | 2.0 | 343878445 | 3554 | 3.18 | Drop the bag and walk away, or I put you in the ground! |
| f5tts-yell-2.wav | order | F5TTS_v1_Base | zira | 32 | 2.0 | 967210975 | 3002 | 3.10 | Everybody on the floor now, hands where I can see them! |
| f5tts-yell-3.wav | panic | F5TTS_v1_Base | lessac | 32 | 2.0 | 1456122455 | 3030 | 3.39 | They're coming through the wall, run, run, don't look back! |
| f5tts-yell-4.wav | taunt | F5TTS_v1_Base | david | 32 | 2.0 | 607951749 | 2907 | 3.47 | Is that all you've got? My grandmother hits harder than you! |
| f5tts-yell-5.wav | slaver | F5TTS_v1_Base | zira | 32 | 2.0 | 4142235047 | 2910 | 3.68 | Move it, cattle! Anyone who stops walking gets left for the dogs! |
| f5tts-yell-6.wav | trader | F5TTS_v1_Base | lessac | 32 | 2.0 | 4107328341 | 3075 | 3.80 | Fresh ammo, two hundred a box, no haggling, no refunds, no crying! |
| f5tts-yell-7.wav | medic | F5TTS_v1_Base | david | 32 | 2.0 | 2465054342 | 3117 | 3.58 | Cover me, he's bleeding out, somebody get me a tourniquet now! |
| f5tts-yell-8.wav | threat | F5TTS_v1_Base | zira | 32 | 2.0 | 1304405886 | 2810 | 2.93 | Touch that door again and I swear you lose the hand! |
| f5tts-yell-9.wav | order | F5TTS_v1_Base | lessac | 32 | 2.0 | 3168068122 | 3158 | 3.56 | Nobody leaves this basement until I find out who took my keys! |
| f5tts-yell-10.wav | panic | F5TTS_v1_Base | david | 32 | 2.0 | 1655368909 | 2915 | 3.35 | The generator's on fire, kill the power, kill it, kill it! |
| f5tts-yell-11.wav | taunt | F5TTS_v1_Base | zira | 32 | 2.0 | 2999311547 | 2888 | 3.22 | Come on then, hero, show everyone what a big man you are! |
| f5tts-yell-12.wav | trader | F5TTS_v1_Base | lessac | 32 | 2.0 | 3178918420 | 3155 | 3.85 | Last call! Water's ten a bottle, tomorrow it's twenty, your choice! |
| f5tts-yell-13.wav | slaver | F5TTS_v1_Base | david | 32 | 2.0 | 682929258 | 3147 | 3.94 | Chain them up, count them twice, I'm not losing another one tonight! |
| f5tts-yell-14.wav | medic | F5TTS_v1_Base | zira | 32 | 2.0 | 1431061664 | 2884 | 3.51 | Stop screaming and hold still, I can't stitch a moving target! |
| f5tts-yell-15-e2.wav | threat | E2TTS_Base | david | 32 | 2.0 | 1967074911 | 4443 | 3.18 | Drop the bag and walk away, or I put you in the ground! |
| f5tts-yell-16-e2.wav | order | E2TTS_Base | zira | 32 | 2.0 | 3307398461 | 3519 | 3.10 | Everybody on the floor now, hands where I can see them! |
| f5tts-yell-17-e2.wav | panic | E2TTS_Base | lessac | 32 | 2.0 | 3950325733 | 3520 | 3.39 | They're coming through the wall, run, run, don't look back! |
| f5tts-yell-18-e2.wav | taunt | E2TTS_Base | david | 32 | 2.0 | 2629977335 | 3785 | 3.47 | Is that all you've got? My grandmother hits harder than you! |
| f5tts-yell-19-e2.wav | slaver | E2TTS_Base | zira | 32 | 2.0 | 3311201345 | 3531 | 3.68 | Move it, cattle! Anyone who stops walking gets left for the dogs! |
| f5tts-yell-20-e2.wav | trader | E2TTS_Base | lessac | 32 | 2.0 | 1667605940 | 3821 | 3.80 | Fresh ammo, two hundred a box, no haggling, no refunds, no crying! |
| f5tts-yell-21-e2.wav | medic | E2TTS_Base | david | 32 | 2.0 | 1171491979 | 3913 | 3.58 | Cover me, he's bleeding out, somebody get me a tourniquet now! |
| f5tts-yell-22-e2.wav | threat | E2TTS_Base | zira | 32 | 2.0 | 2305165252 | 3481 | 2.93 | Touch that door again and I swear you lose the hand! |
| f5tts-yell-23-e2.wav | order | E2TTS_Base | lessac | 32 | 2.0 | 1788593196 | 3866 | 3.56 | Nobody leaves this basement until I find out who took my keys! |
| f5tts-yell-24-e2.wav | panic | E2TTS_Base | david | 32 | 2.0 | 628251003 | 3545 | 3.35 | The generator's on fire, kill the power, kill it, kill it! |
| f5tts-yell-25-e2.wav | taunt | E2TTS_Base | zira | 32 | 2.0 | 3315277168 | 3590 | 3.22 | Come on then, hero, show everyone what a big man you are! |
| f5tts-yell-26-e2.wav | trader | E2TTS_Base | lessac | 32 | 2.0 | 1568560854 | 3933 | 3.85 | Last call! Water's ten a bottle, tomorrow it's twenty, your choice! |
| f5tts-yell-27-e2.wav | slaver | E2TTS_Base | david | 32 | 2.0 | 1554503425 | 4337 | 3.94 | Chain them up, count them twice, I'm not losing another one tonight! |
| f5tts-yell-28-e2.wav | medic | E2TTS_Base | zira | 32 | 2.0 | 2036074144 | 3581 | 3.51 | Stop screaming and hold still, I can't stitch a moving target! |
| f5tts-yell-29-nfe16.wav | threat | F5TTS_v1_Base | david | 16 | 2.0 | 2861508875 | 2135 | 3.18 | Drop the bag and walk away, or I put you in the ground! |
| f5tts-yell-30-nfe16.wav | order | F5TTS_v1_Base | zira | 16 | 2.0 | 1313518045 | 2866 | 3.10 | Everybody on the floor now, hands where I can see them! |
| f5tts-yell-31-nfe16.wav | panic | F5TTS_v1_Base | lessac | 16 | 2.0 | 3997974938 | 1525 | 3.39 | They're coming through the wall, run, run, don't look back! |
| f5tts-yell-32-nfe16.wav | taunt | F5TTS_v1_Base | david | 16 | 2.0 | 3273159032 | 1482 | 3.47 | Is that all you've got? My grandmother hits harder than you! |
| f5tts-yell-33-nfe16.wav | slaver | F5TTS_v1_Base | zira | 16 | 2.0 | 2868026864 | 1487 | 3.68 | Move it, cattle! Anyone who stops walking gets left for the dogs! |
| f5tts-yell-34-nfe16.wav | trader | F5TTS_v1_Base | lessac | 16 | 2.0 | 2493713170 | 1618 | 3.80 | Fresh ammo, two hundred a box, no haggling, no refunds, no crying! |
| f5tts-yell-35-nfe16.wav | medic | F5TTS_v1_Base | david | 16 | 2.0 | 2108708525 | 1662 | 3.58 | Cover me, he's bleeding out, somebody get me a tourniquet now! |
| f5tts-yell-36-nfe16.wav | threat | F5TTS_v1_Base | zira | 16 | 2.0 | 3205448991 | 1478 | 2.93 | Touch that door again and I swear you lose the hand! |
| f5tts-yell-37-nfe16.wav | order | F5TTS_v1_Base | lessac | 16 | 2.0 | 3713504697 | 1659 | 3.56 | Nobody leaves this basement until I find out who took my keys! |
| f5tts-yell-38-nfe16.wav | panic | F5TTS_v1_Base | david | 16 | 2.0 | 2842039665 | 1506 | 3.35 | The generator's on fire, kill the power, kill it, kill it! |
| f5tts-yell-39-nfe16.wav | taunt | F5TTS_v1_Base | zira | 16 | 2.0 | 1224209174 | 1522 | 3.22 | Come on then, hero, show everyone what a big man you are! |
| f5tts-yell-40-nfe16.wav | trader | F5TTS_v1_Base | lessac | 16 | 2.0 | 3080541296 | 1724 | 3.85 | Last call! Water's ten a bottle, tomorrow it's twenty, your choice! |
| f5tts-yell-41-nfe16.wav | slaver | F5TTS_v1_Base | david | 16 | 2.0 | 931588435 | 1809 | 3.94 | Chain them up, count them twice, I'm not losing another one tonight! |
| f5tts-yell-42-nfe16.wav | medic | F5TTS_v1_Base | zira | 16 | 2.0 | 2246629530 | 3958 | 3.51 | Stop screaming and hold still, I can't stitch a moving target! |
