// A source-time gap is not a new layout. Keep the complete previous frame until
// the master decoder lands in the next retained cut.
export function layoutAtRaw(project,t){
 const cut=project.cuts?.find(c=>t>=c.source_start&&t<c.source_end);
 if(!cut)return null;
 const layout={mode:'pip',...cut.layout};
 if(layout.mode==='pip'){
  layout.rect??=[Math.round(project.width*.79),Math.round(project.height*.66),Math.round(project.height*.30),Math.round(project.height*.30)];
  layout.camera_crop??=[.21875,0,.5625,1];
 }
 return layout;
}
