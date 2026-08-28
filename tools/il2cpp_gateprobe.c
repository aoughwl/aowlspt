/* child: gatecall <export> <tokrva-hex> <argindex> <good|bad|null> */
#include <windows.h>
#include <stdio.h>
typedef unsigned long long u64;
typedef u64(*f0)(void*,void*,void*,void*,void*);
int main(int c,char**v){
  setvbuf(stdout,NULL,_IONBF,0);
  if(c<5)return 2;
  SetDllDirectoryA("D:/Games/Tarkov");
  HMODULE h=LoadLibraryExA("D:/Games/Tarkov/GameAssembly.dll",NULL,LOAD_WITH_ALTERED_SEARCH_PATH);
  if(!h){printf("LOADFAIL\n");return 3;}
  unsigned char*base=(unsigned char*)h;
  f0 f=(f0)GetProcAddress(h,v[1]);
  if(!f){printf("NOEXPORT\n");return 4;}
  unsigned rva=(unsigned)strtoul(v[2],0,16);
  int ai=atoi(v[3]);
  unsigned char tok[32]; memcpy(tok,base+rva,32);
  if(!strcmp(v[4],"bad")) tok[0]^=0xFF;
  void* t = strcmp(v[4],"null")? (void*)tok : NULL;
  /* staged receiver we own: zeroed, 4KB, readable+writable */
  unsigned char*mi=(unsigned char*)VirtualAlloc(0,0x1000,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
  memset(mi,0,0x1000); mi[0x52]=7; /* param_count field */
  void*a[5]={mi,0,0,0,0};
  a[ai]=t;
  for(int i=0;i<3;i++){
    u64 r=f(a[0],a[1],a[2],a[3],a[4]);
    printf("%llX\n",r);
  }
  return 0;
}
