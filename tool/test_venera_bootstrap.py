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
async function checkLoadNextExplore(){
 const calls=[];
 globalThis.__zicSource={
   url:'https://e.invalid/source.js',
   comic:{},
   explore:[{title:'latest',loadNext:async next=>{calls.push(next);return next===null?{comics:[{id:'https://e.invalid/g/1',title:'Page 1A',cover:'/cover-1.jpg'},{id:'https://e.invalid/g/1b',title:'Page 1B'}],next:'page-2'}:{comics:[{id:'https://e.invalid/g/2',title:'Page 2'}],next:null}}}]
 };
 if(!__zicHasBrowseCapability(globalThis.__zicSource))throw new Error('loadNext capability not discovered');
 const first=await __zicOperation({operation:'browse',arguments:{query:'',offset:0,limit:1}});
 const second=await __zicOperation({operation:'browse',arguments:{query:'',offset:1,limit:1}});
 const third=await __zicOperation({operation:'browse',arguments:{query:'',offset:2,limit:1}});
 if(first.items[0].title!=='Page 1A'||first.items[0].coverUri!=='https://e.invalid/cover-1.jpg'||!first.hasMore)throw new Error('loadNext first slice failed '+JSON.stringify(first));
 if(second.items[0].title!=='Page 1B'||!second.hasMore)throw new Error('loadNext retained slice failed '+JSON.stringify(second));
 if(third.items[0].title!=='Page 2'||third.hasMore)throw new Error('loadNext second source page failed '+JSON.stringify(third));
 if(JSON.stringify(calls)!==JSON.stringify([null,'page-2']))throw new Error('loadNext tokens '+JSON.stringify(calls));
}

async function checkLegacyGlobalScratchBinding(){
 class LegacySource extends ComicSource {
   key='legacy';name='Legacy';url='https://legacy.invalid/';
   explore=[{load:async()=>[{id:'comic',title:'Legacy comic'}]}];
   comic={loadInfo:async(id)=>{res={title:'Legacy detail',chapters:{one:'One'}};return res}};
 }
 globalThis.__zicSource=new LegacySource();
 const browse=await __zicOperation({operation:'browse',arguments:{query:'',offset:0,limit:20}});
 const detail=await __zicOperation({operation:'loadComic',arguments:{comicId:browse.items[0].comicId}});
 if(detail.comic.title!=='Legacy detail'||detail.chapters[0].title!=='One')throw new Error('legacy res binding failed '+JSON.stringify(detail));
 const detailMessage=__zicErrorMessage(new ReferenceError('boom'),'loadComic');
 if(!detailMessage.startsWith('loadComic: boom'))throw new Error('operation error context failed '+detailMessage);
}

async function checkDirectCoverResource(){
 let seen=null;
 ZicNative.request=raw=>{
   const message=__zicDecode(JSON.parse(raw));seen=message;
   if(message.method!=='http')throw new Error('unexpected direct cover bridge method '+message.method);
   return JSON.stringify({ok:true,value:__zicEncode({status:200,headers:{'content-type':'image/jpeg'},body:new Uint8Array([1,2,3]).buffer})});
 };
 globalThis.__zicSource={comic:{}};
 const bytes=await __zicOperation({operation:'loadResource',arguments:{uri:'https://cdn.invalid/cover.jpg'}});
 if(!(bytes instanceof ArrayBuffer)||JSON.stringify(Array.from(new Uint8Array(bytes)))!==JSON.stringify([1,2,3]))throw new Error('direct cover bytes failed');
 if(seen.url!=='https://cdn.invalid/cover.jpg'||seen.http_method!=='GET')throw new Error('direct cover request failed '+JSON.stringify(seen));
}
(async()=>{await checkCurrentCategory();await checkLegacyCategory();await checkExploreObject();await checkLoadNextExplore();await checkLegacyGlobalScratchBinding();await checkDirectCoverResource();console.log('Venera bootstrap contract: OK')})().catch(e=>{console.error(e);process.exit(1)});
'''
with tempfile.TemporaryDirectory() as td:
    js=Path(td)/'test.js'; js.write_text(bootstrap+'\n'+test)
    subprocess.run(['node',str(js)],check=True)
