import numpy as np, struct
def load(path):
    with open(path,'rb') as f:
        data=f.read()
    n=struct.unpack('<I',data[80:84])[0]
    if 84+n*50==len(data):
        rec=np.frombuffer(data[84:84+n*50],dtype=np.dtype([('n','<f4',3),('v','<f4',(3,3)),('a','<u2')]))
        return rec['v'].astype(float)
    # ascii fallback
    vs=[]
    for line in data.decode('ascii','ignore').splitlines():
        line=line.strip()
        if line.startswith('vertex'):
            vs.append([float(t) for t in line.split()[1:4]])
    return np.array(vs).reshape(-1,3,3)
