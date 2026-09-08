'use client';
import { useState } from 'react';
import { Copy, Check } from 'lucide-react';
import { Button } from '@/components/ui/button';
export default function Endpoint() {
  const [state,setState]=useState('');
  return <><div className="endpoint"><code>https://mcp.healthmcp.cc/mcp</code><Button aria-label="Copy MCP server URL" onClick={async()=>{try{await navigator.clipboard.writeText('https://mcp.healthmcp.cc/mcp');setState('Server URL copied.')}catch{setState('Select and copy the server URL above.')}}} className="h-9 rounded-md bg-[#172722] px-4 text-white hover:bg-[#315344]">{state==='Server URL copied.'?<Check/>:<Copy/>} Copy URL</Button></div><span className="copy-status" role="status">{state}</span></>;
}
