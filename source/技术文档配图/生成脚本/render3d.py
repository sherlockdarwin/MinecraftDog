import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import dg  # fonts
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from matplotlib.colors import to_rgb
import stl

D = '/Users/sherlockdarwin/code/FPGA/MinecraftDog/3Dmodel/stls'
OUT = sys.argv[1]
PARTS = [  # file, name, color, explode offset (x, fwd, up) mm
    ('body', '躯干 body', '#B0BEC5', (0, 0, 0)),
    ('body_cover', '躯干盖板 body_cover', '#78909C', (0, 0, 70)),
    ('breast', '胸腔 breast', '#FFCC80', (0, 25, 0)),
    ('breast_cover', '胸腔盖板 breast_cover', '#FB8C00', (0, 25, 90)),
    ('head', '头部 head', '#A5D6A7', (0, 80, 20)),
    ('ears', '耳朵 ears', '#66BB6A', (0, 80, 75)),
    ('left_front', '左前腿 left_front', '#90CAF9', (45, 25, -45)),
    ('right_front', '右前腿 right_front', '#90CAF9', (-45, 25, -45)),
    ('left_back', '左后腿 left_back', '#CE93D8', (45, -20, -45)),
    ('right_back', '右后腿 right_back', '#CE93D8', (-45, -20, -45)),
    ('tail', '尾巴 tail', '#EF9A9A', (0, -70, 20)),
]


def tris(name, off=(0, 0, 0)):
    v = stl.load(f'{D}/{name}.stl')
    # file axes: x = side, y = forward, z = down  ->  (x, y, up)
    v = np.stack([v[..., 0], v[..., 1], -v[..., 2]], axis=-1)
    return v + np.array(off, dtype=float)


def render(path, explode=False, elev=22, azim=-128, size=(7.5, 5.6), legend=False):
    allv, cols = [], []
    L = np.array([0.4, -0.6, 0.7]); L /= np.linalg.norm(L)
    for f, n, c, off in PARTS:
        v = tris(f, off if explode else (0, 0, 0))
        nrm = np.cross(v[:, 1] - v[:, 0], v[:, 2] - v[:, 0])
        ln = np.linalg.norm(nrm, axis=1, keepdims=True); ln[ln == 0] = 1
        inten = 0.45 + 0.55 * np.abs((nrm / ln) @ L)
        base = np.array(to_rgb(c))
        cols.append(np.clip(base[None, :] * inten[:, None], 0, 1))
        allv.append(v)
    V = np.concatenate(allv); Cc = np.concatenate(cols)
    fig = plt.figure(figsize=size)
    ax = fig.add_axes([0, 0, 1, 1], projection='3d')
    pc = Poly3DCollection(V, facecolors=Cc, edgecolors=Cc * 0.8, linewidths=0.15)
    ax.add_collection3d(pc)
    a = V.reshape(-1, 3); lo, hi = a.min(0), a.max(0)
    ax.set_xlim(lo[0], hi[0]); ax.set_ylim(lo[1], hi[1]); ax.set_zlim(lo[2], hi[2])
    ax.set_box_aspect(hi - lo)
    ax.view_init(elev=elev, azim=azim)
    ax.set_axis_off()
    if legend:
        from matplotlib.patches import Patch
        seen = {}
        for f, n, c, off in PARTS:
            key = n.split(' ')[0].replace('左', '').replace('右', '') if '腿' in n else n
            if '腿' in n:
                key = ('前腿 left/right_front' if 'front' in f else '后腿 left/right_back')
            seen.setdefault(key, c)
        ax.legend(handles=[Patch(fc=c, ec='#607D8B', label=k) for k, c in seen.items()], loc='lower left',
                  fontsize=8, frameon=False, bbox_to_anchor=(0.0, 0.0))
    fig.savefig(path, dpi=220, facecolor='white', bbox_inches='tight', pad_inches=0.02)
    plt.close(fig)


render(f'{OUT}/3d_iso.png', elev=20, azim=52)
render(f'{OUT}/3d_side.png', elev=4, azim=0, size=(7.5, 4.2))
render(f'{OUT}/3d_explode.png', explode=True, elev=24, azim=48, legend=True)
print('ok')
