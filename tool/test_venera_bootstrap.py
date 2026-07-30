#!/usr/bin/env python3
import re, subprocess, tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source=(root/'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt').read_text()
m=re.search(r'private const val VENERA_BOOTSTRAP = """\n(.*?)\n"""', source, re.S)
if not m: raise SystemExit('VENERA_BOOTSTRAP not found')
bootstrap=m.group(1)
test=r'''
globalThis.ZicNative={request(){throw new Error('native bridge unexpectedly used')},complete(){},activated(){}};
async function checkCurrentCategory(){
 let seen=null;
 globalThis.__zicSource={
   category:{itemType:'category',parts:[{categories:['最新','热门'],categoryParams:['new','hot']}]},
   categoryComics:{
     optionLoader:async(category,param)=>[{options:[{value:'all'}],default:'all'}],
     load:async(category,param,options,page)=>{seen={category,param,options,page};return {comics:[{id:'1',title:'Current'}],maxPage:2}}
   }
 };
 const value=await __zicOperation({operation:'browse',arguments:{query:'',offset:0,limit:20}});
 if(value.items.length!==1||value.items[0].title!=='Current')throw new Error('current category result failed');
 if(JSON.stringify(seen)!==JSON.stringify({category:'最新',param:'new',options:['all'],page:1}))throw new Error('current category arguments '+JSON.stringify(seen));
}
async function checkLegacyCategory(){
 let seen=null;
 globalThis.__zicSource={category:{parts:[{categories:[{target:{page:'category',attributes:{category:'legacy',param:'p'}}}]}]},categoryComics:{optionList:[{options:['x-y']}],load:async(...args)=>{seen=args;return [{id:'2',title:'Legacy'}]}}};
 const value=await __zicOperation({operation:'browse',arguments:{query:'',offset:0,limit:20}});
 if(value.items[0].title!=='Legacy'||seen[0]!=='legacy'||seen[1]!=='p'||seen[2][0]!=='x')throw new Error('legacy category failed');
}
async function checkExploreObject(){
 globalThis.__zicSource={explore:{home:{load:async page=>({sections:new Map([['a',[{id:'3',title:'Explore'}]]]),maxPage:page})}}};
 const value=await __zicOperation({operation:'browse',arguments:{query:'',offset:0,limit:20}});
 if(value.items[0].title!=='Explore')throw new Error('explore object failed');
}
(async()=>{await checkCurrentCategory();await checkLegacyCategory();await checkExploreObject();console.log('Venera bootstrap contract: OK')})().catch(e=>{console.error(e);process.exit(1)});
'''
with tempfile.TemporaryDirectory() as td:
    js=Path(td)/'test.js'; js.write_text(bootstrap+'\n'+test)
    subprocess.run(['node',str(js)],check=True)
