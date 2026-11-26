static void dump(const struct wl_interface *i){
 printf("%s v%d %d %d\n", i->name, i->version, i->method_count, i->event_count);
 const struct wl_message *ms[2]={i->methods,i->events}; int cs[2]={i->method_count,i->event_count};
 for(int k=0;k<2;k++) for(int j=0;j<cs[k];j++){ const struct wl_message *m=&ms[k][j]; printf("  %s %s", m->name, m->signature);
  int n=0; for(const char*c=m->signature;*c;c++) if(*c!='?'&&(*c<'0'||*c>'9')) n++;
  for(int a=0;a<n;a++){ const struct wl_interface *t=m->types?m->types[a]:0; printf(" %s", t?t->name:"-"); } printf("\n"); } }
